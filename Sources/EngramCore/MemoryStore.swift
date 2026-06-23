import Foundation
import CSQLite

/// The store: owns the SQLite + sqlite-vec database and exposes the operations
/// the CLI hooks and the app UI both need. An `actor` (ADR 0006) so its SQLite
/// connection and embedder are isolated and concurrent callers are serialized;
/// cross-process safety still rests on SQLite `FULLMUTEX` + `busy_timeout`.
public actor MemoryStore {
    private let db: SQLiteDatabase
    /// `var` so `reindex()` can swap in a freshly-built embedder mid-session once
    /// the contextual model's assets have downloaded (ADR 0012).
    private var embedder: Embedder
    private let databaseURL: URL

    public init(url: URL = EngramPaths.defaultDatabaseURL, embedder: Embedder? = nil) throws {
        self.databaseURL = url
        let db = try SQLiteDatabase(path: url.path)
        self.db = db
        self.embedder = try embedder ?? Embedder()
        try Self.migrate(db: db, embedder: self.embedder, databaseURL: url)
    }

    /// True when recall is running on the degraded fallback embedder because the
    /// contextual model's assets weren't available at launch (ADR 0012). Lets the
    /// app warn that semantic recall is weaker until `reindex()` (or a relaunch).
    public var isUsingFallbackEmbedder: Bool { embedder.isFallback }

    /// The live embedder's signature (backend + dimension), e.g. `contextual-512`.
    /// Drives embedder-relative recall gating (`RecallGate.config(for:)`).
    public var embedderSignature: String { embedder.signature }

    /// Rebuilds the embedder from scratch — picking up contextual-model assets
    /// that have downloaded since launch — and re-embeds every memory if the
    /// backend changed (the migration is signature-gated, so it's a cheap no-op
    /// when nothing changed). This is the in-session recovery from a degraded
    /// launch (ADR 0012) for a long-lived app: re-index on demand instead of
    /// waiting for a relaunch. Returns `true` if it's now on the full contextual
    /// model (no longer the fallback). Runs on the actor, so it serializes with
    /// other store work.
    @discardableResult
    public func reindex() throws -> Bool {
        embedder = try Embedder()
        try Self.migrateVectorStore(db: db, embedder: embedder, databaseURL: databaseURL)
        return !embedder.isFallback
    }

    private static func migrate(db: SQLiteDatabase, embedder: Embedder, databaseURL: URL) throws {
        try createSchema(db)
        try addMissingColumns(db)
        try addMissingRetrievalColumns(db)
        try migrateVectorStore(db: db, embedder: embedder, databaseURL: databaseURL)
        try backfillFTS(db)
    }

    /// Additively adds the `session_id` column the retrievals ledger grew for the
    /// session-scoped recall cooldown (ADR 0023). No-op on an already-migrated DB.
    private static func addMissingRetrievalColumns(_ db: SQLiteDatabase) throws {
        var existingColumns = Set<String>()
        try db.prepare("PRAGMA table_info(retrievals);") { stmt in
            while try stmt.step() {
                if let name = stmt.columnText(1) { existingColumns.insert(name) }
            }
        }
        if !existingColumns.contains("session_id") {
            try db.exec("ALTER TABLE retrievals ADD COLUMN session_id TEXT;")
        }
        // Create the index here (not in createSchema) so it's only built once the
        // session_id column is guaranteed to exist — on a fresh DB and on an
        // upgraded one alike. Referencing it in createSchema fails on old DBs
        // whose retrievals table predates the column.
        try db.exec("CREATE INDEX IF NOT EXISTS idx_retrievals_session ON retrievals(session_id, memory_id, at);")
    }

    private static func createSchema(_ db: SQLiteDatabase) throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS memories(
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                source TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_accessed_at REAL,
                access_count INTEGER NOT NULL DEFAULT 0,
                deleted_at REAL
            );
            CREATE TABLE IF NOT EXISTS memory_tags(
                memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                tag TEXT NOT NULL,
                PRIMARY KEY(memory_id, tag)
            );
            CREATE TABLE IF NOT EXISTS events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                memory_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_events_at ON events(at);
            CREATE TABLE IF NOT EXISTS retrievals(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                memory_id TEXT NOT NULL,
                source TEXT NOT NULL,
                query TEXT,
                at REAL NOT NULL,
                session_id TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_retrievals_at ON retrievals(at);
            CREATE INDEX IF NOT EXISTS idx_memories_deleted ON memories(deleted_at);
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
                memory_id UNINDEXED, content, tags, tokenize='porter unicode61'
            );
            """
        )
    }

    /// Additively adds columns the schema has grown over time — verification
    /// fields (ADR 0008) and the display `title` (ADR 0014). SQLite has no `ADD
    /// COLUMN IF NOT EXISTS`, so read the current columns first and only add the
    /// missing ones — making this a no-op on an already-migrated DB.
    private static func addMissingColumns(_ db: SQLiteDatabase) throws {
        var existingColumns = Set<String>()
        try db.prepare("PRAGMA table_info(memories);") { stmt in
            while try stmt.step() {
                if let name = stmt.columnText(1) { existingColumns.insert(name) }
            }
        }
        let optionalColumns: [(name: String, definition: String)] = [
            ("verifiability", "TEXT DEFAULT 'userConfirmOnly'"),
            ("check_anchor", "TEXT"),
            ("verified_at", "REAL"),
            ("confidence", "REAL DEFAULT 1.0"),
            ("superseded_by", "TEXT"),
            ("evolution_reason", "TEXT"),
            ("title", "TEXT"),
        ]
        for column in optionalColumns where !existingColumns.contains(column.name) {
            try db.exec("ALTER TABLE memories ADD COLUMN \(column.name) \(column.definition);")
        }
    }

    /// Creates `vec_memories` at the live embedder's dimension and re-embeds all
    /// memories whenever the embedder changes (ADR 0012) — a fresh upgrade, or the
    /// contextual model's assets becoming available between launches.
    private static func migrateVectorStore(db: SQLiteDatabase, embedder: Embedder, databaseURL: URL) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);")
        if try readMeta(db, "embedder_signature") == embedder.signature {
            try db.exec(createVectorTableSQL(dimension: embedder.dimension))
            return
        }
        // Embedder changed (or first run on a pre-existing store): rebuild the
        // vector table at the new dimension and re-embed every memory. The
        // migration below is transactional, but copy the DB to a sibling backup
        // first as a belt-and-suspenders recovery point should a botched embedder
        // migration corrupt the store. Best-effort: never block the migration.
        backupBeforeReembed(databaseURL)
        // …in ONE transaction so an interruption (crash, or an embed that throws)
        // rolls back to the prior table with the signature unwritten, leaving the
        // store consistent and the migration to retry cleanly next launch (rather
        // than a silently half-embedded store with missing vectors).
        try db.exec("BEGIN;")
        do {
            try db.exec("DROP TABLE IF EXISTS vec_memories;")
            try db.exec(createVectorTableSQL(dimension: embedder.dimension))
            try reembedAll(db: db, embedder: embedder)
            try writeMeta(db, "embedder_signature", embedder.signature)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    /// Copies the SQLite file to a sibling `*.pre-reembed-bak` before the
    /// destructive re-embed migration, so a botched migration is recoverable.
    /// Best-effort (`try?`) — failure here must never block the migration — and
    /// re-applies the 0600 owner-only perms the store keeps (Domain/SQLite).
    private static func backupBeforeReembed(_ databaseURL: URL) {
        let backupURL = databaseURL.appendingPathExtension("pre-reembed-bak")
        try? FileManager.default.removeItem(at: backupURL)
        guard (try? FileManager.default.copyItem(at: databaseURL, to: backupURL)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    private static func createVectorTableSQL(dimension: Int) -> String {
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories USING vec0(
            memory_id TEXT PRIMARY KEY,
            embedding FLOAT[\(dimension)] distance_metric=cosine
        );
        """
    }

    /// Recomputes and stores every active memory's embedding (used after the
    /// embedder changes). Vectors only — content/tags/FTS are untouched.
    private static func reembedAll(db: SQLiteDatabase, embedder: Embedder) throws {
        var rows: [(id: String, content: String)] = []
        try db.prepare("SELECT id, content FROM memories WHERE deleted_at IS NULL AND superseded_by IS NULL;") { stmt in
            while try stmt.step() {
                if let id = stmt.columnText(0), let content = stmt.columnText(1) {
                    rows.append((id, content))
                }
            }
        }
        for row in rows {
            let vector = try embedder.vector(for: row.content)
            try db.prepare("INSERT INTO vec_memories(memory_id, embedding) VALUES(?, ?);") { stmt in
                stmt.bind(row.id, at: 1).bindBlob(Self.floatBlob(vector), at: 2)
                _ = try stmt.step()
            }
        }
    }

    private static func readMeta(_ db: SQLiteDatabase, _ key: String) throws -> String? {
        var value: String?
        try db.prepare("SELECT value FROM meta WHERE key = ?;") { stmt in
            stmt.bind(key, at: 1)
            if try stmt.step() { value = stmt.columnText(0) }
        }
        return value
    }

    private static func writeMeta(_ db: SQLiteDatabase, _ key: String, _ value: String) throws {
        try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);") { stmt in
            stmt.bind(key, at: 1).bind(value, at: 2)
            _ = try stmt.step()
        }
    }

    /// Backfill the lexical index for any active memory missing from it
    /// (e.g. rows that predate the FTS table). Idempotent.
    private static func backfillFTS(_ db: SQLiteDatabase) throws {
        try db.exec(
            """
            INSERT INTO memories_fts(memory_id, content, tags)
            SELECT m.id, m.content,
                   COALESCE((SELECT group_concat(tag, ' ') FROM memory_tags WHERE memory_id = m.id), '')
            FROM memories m
            WHERE m.deleted_at IS NULL
              AND m.superseded_by IS NULL
              AND m.id NOT IN (SELECT memory_id FROM memories_fts);
            """
        )
    }

    // MARK: - Writes

    /// Stores a new memory and its embedding. Returns the persisted record.
    @discardableResult
    public func store(
        title: String? = nil,
        content: String,
        tags: [String] = [],
        source: String? = nil,
        verifiability: Verifiability = .userConfirmOnly,
        checkAnchor: String? = nil
    ) throws -> Memory {
        let memory = Memory(
            title: Self.cleanTitle(title),
            content: content,
            tags: normalize(tags),
            source: source,
            verifiability: verifiability,
            checkAnchor: checkAnchor
        )
        let vector = try embedder.vector(for: content)

        try db.exec("BEGIN;")
        do {
            try insertMemoryRow(memory)
            try insertTags(memory.tags, for: memory.id)
            try insertVector(vector, for: memory.id)
            try insertFTS(content: memory.content, tags: memory.tags, for: memory.id)
            try recordEvent(.created, for: memory.id)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
        return memory
    }

    /// Updates content and/or tags of an existing memory, re-embedding if the
    /// content changed. Bumps `updated_at` and logs an `updated` event.
    @discardableResult
    public func update(
        id: UUID,
        title: String?? = nil,
        content: String? = nil,
        tags: [String]? = nil,
        source: String? = nil,
        verifiability: Verifiability? = nil,
        checkAnchor: String? = nil
    ) throws -> Memory? {
        guard var memory = fetch(id: id) else { return nil }
        let contentChanged = content != nil && content != memory.content
        if let title { memory.title = Self.cleanTitle(title) }
        if let content { memory.content = content }
        if let tags { memory.tags = normalize(tags) }
        if let source { memory.source = source }
        if let verifiability { memory.verifiability = verifiability }
        if let checkAnchor { memory.checkAnchor = checkAnchor }
        memory.updatedAt = Date()

        try persistUpdate(memory, replaceTags: tags != nil, contentChanged: contentChanged)
        return memory
    }

    /// Writes an updated memory row in a single transaction, replacing the tag
    /// rows and embedding vector only when those changed.
    private func persistUpdate(_ memory: Memory, replaceTags: Bool, contentChanged: Bool) throws {
        try db.exec("BEGIN;")
        do {
            try db.prepare("UPDATE memories SET title=?, content=?, source=?, verifiability=?, check_anchor=?, updated_at=? WHERE id=?;") { stmt in
                stmt.bind(memory.title, at: 1)
                    .bind(memory.content, at: 2)
                    .bind(memory.source, at: 3)
                    .bind(memory.verifiability.rawValue, at: 4)
                    .bind(memory.checkAnchor, at: 5)
                    .bind(memory.updatedAt.timeIntervalSince1970, at: 6)
                    .bind(memory.id.uuidString, at: 7)
                _ = try stmt.step()
            }
            if replaceTags {
                try db.prepare("DELETE FROM memory_tags WHERE memory_id=?;") { stmt in
                    stmt.bind(memory.id.uuidString, at: 1); _ = try stmt.step()
                }
                try insertTags(memory.tags, for: memory.id)
            }
            if contentChanged {
                let vector = try embedder.vector(for: memory.content)
                try db.prepare("DELETE FROM vec_memories WHERE memory_id=?;") { stmt in
                    stmt.bind(memory.id.uuidString, at: 1); _ = try stmt.step()
                }
                try insertVector(vector, for: memory.id)
            }
            // Content and/or tags may have changed; refresh the lexical index.
            try deleteFTS(for: memory.id)
            try insertFTS(content: memory.content, tags: memory.tags, for: memory.id)
            try recordEvent(.updated, for: memory.id)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    /// Marks a memory as verified now, optionally updating its confidence. Used
    /// by the `/dream` flow when a check confirms a memory is still true (ADR
    /// 0008). Returns the reloaded memory, or nil if no such row exists.
    @discardableResult
    public func markVerified(id: UUID, confidence: Double?) throws -> Memory? {
        guard fetch(id: id) != nil else { return nil }
        let now = Date().timeIntervalSince1970
        try db.exec("BEGIN;")
        do {
            if let confidence {
                try db.prepare("UPDATE memories SET verified_at=?, confidence=? WHERE id=?;") { stmt in
                    stmt.bind(now, at: 1).bind(confidence, at: 2).bind(id.uuidString, at: 3)
                    _ = try stmt.step()
                }
            } else {
                try db.prepare("UPDATE memories SET verified_at=? WHERE id=?;") { stmt in
                    stmt.bind(now, at: 1).bind(id.uuidString, at: 2)
                    _ = try stmt.step()
                }
            }
            try recordEvent(.updated, for: id)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
        return fetch(id: id)
    }

    /// Supersedes an old memory with a new one (ADR 0008): stores the new memory
    /// and links the old via `superseded_by`/`evolution_reason`, dropping the old
    /// row from the vector and lexical indexes so it stops matching recall while
    /// its history is preserved. Returns the new memory, or nil if the old id
    /// doesn't exist.
    @discardableResult
    public func supersede(
        id: UUID,
        content: String,
        reason: String,
        tags: [String],
        source: String?,
        verifiability: Verifiability
    ) throws -> Memory? {
        guard let oldMemory = fetch(id: id) else { return nil }
        // Inherit the old memory's class when inference couldn't classify the new
        // one (ADR 0008) — superseding shouldn't silently demote verifiability.
        let resolvedVerifiability = verifiability == .userConfirmOnly ? oldMemory.verifiability : verifiability
        let newMemory = Memory(
            content: content,
            tags: normalize(tags),
            source: source,
            verifiability: resolvedVerifiability
        )
        let vector = try embedder.vector(for: content)

        try db.exec("BEGIN;")
        do {
            try insertMemoryRow(newMemory)
            try insertTags(newMemory.tags, for: newMemory.id)
            try insertVector(vector, for: newMemory.id)
            try insertFTS(content: newMemory.content, tags: newMemory.tags, for: newMemory.id)
            try recordEvent(.created, for: newMemory.id)

            try db.prepare("UPDATE memories SET superseded_by=?, evolution_reason=? WHERE id=?;") { stmt in
                stmt.bind(newMemory.id.uuidString, at: 1).bind(reason, at: 2).bind(id.uuidString, at: 3)
                _ = try stmt.step()
            }
            // Drop the superseded memory from the recall indexes (it stays in
            // `memories` for history).
            try db.prepare("DELETE FROM vec_memories WHERE memory_id=?;") { stmt in
                stmt.bind(id.uuidString, at: 1); _ = try stmt.step()
            }
            try deleteFTS(for: id)
            try recordEvent(.updated, for: id)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
        return newMemory
    }

    /// Soft-deletes a memory (keeps the row + tombstone for future sync).
    public func delete(id: UUID) throws {
        try db.exec("BEGIN;")
        do {
            try db.prepare("UPDATE memories SET deleted_at=? WHERE id=? AND deleted_at IS NULL;") { stmt in
                stmt.bind(Date().timeIntervalSince1970, at: 1).bind(id.uuidString, at: 2)
                _ = try stmt.step()
            }
            try db.prepare("DELETE FROM vec_memories WHERE memory_id=?;") { stmt in
                stmt.bind(id.uuidString, at: 1); _ = try stmt.step()
            }
            try deleteFTS(for: id)
            try recordEvent(.deleted, for: id)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Reads

    /// Hybrid search: fuses semantic (sqlite-vec cosine) and lexical (FTS5/BM25)
    /// results with Reciprocal Rank Fusion, drops tombstoned rows, and blends in
    /// recency/frequency via `Ranking`.
    ///
    /// - Parameter recordAccess: when true (default), the returned memories are
    ///   marked accessed (counters + events). The automatic recall hook passes
    ///   `false` so per-prompt recall doesn't inflate `access_count` into a
    ///   rich-get-richer ranking loop.
    public func fetch(query: String, limit: Int = 5, recordAccess: Bool = true) throws -> [ScoredMemory] {
        let candidateCount = max(limit * 5, limit + 10)
        let vector = try embedder.vector(for: query)
        let (vectorRanking, distances) = try semanticCandidates(for: vector, limit: candidateCount)
        let lexicalRanking = try lexicalCandidates(for: query, limit: candidateCount)

        let fused = fuse(
            vectorRanking: vectorRanking,
            lexicalRanking: lexicalRanking,
            distances: distances,
            lexicalIDs: Set(lexicalRanking),
            now: Date()
        )
        let top = Array(fused.prefix(limit))
        if recordAccess { try markAccessed(top.map(\.memory.id)) }
        return top
    }

    /// Semantic stage: sqlite-vec cosine KNN. Returns the ranked candidate ids
    /// and their distances.
    private func semanticCandidates(for vector: [Float], limit: Int) throws -> (ranking: [UUID], distances: [UUID: Double]) {
        var ranking: [UUID] = []
        var distances: [UUID: Double] = [:]
        try db.prepare(
            "SELECT memory_id, distance FROM vec_memories WHERE embedding MATCH ? AND k = ? ORDER BY distance;"
        ) { stmt in
            stmt.bindBlob(Self.floatBlob(vector), at: 1).bind(Int64(limit), at: 2)
            while try stmt.step() {
                guard let s = stmt.columnText(0), let id = UUID(uuidString: s) else { continue }
                ranking.append(id)
                distances[id] = stmt.columnDouble(1) ?? .greatestFiniteMagnitude
            }
        }
        return (ranking, distances)
    }

    /// Lexical stage: FTS5 BM25 keyword match (empty/invalid query → no hits).
    private func lexicalCandidates(for query: String, limit: Int) throws -> [UUID] {
        guard let match = Self.ftsMatchExpression(for: query) else { return [] }
        var ranking: [UUID] = []
        try db.prepare(
            "SELECT memory_id FROM memories_fts WHERE memories_fts MATCH ? ORDER BY rank LIMIT ?;"
        ) { stmt in
            stmt.bind(match, at: 1).bind(Int64(limit), at: 2)
            while try stmt.step() {
                if let s = stmt.columnText(0), let id = UUID(uuidString: s) { ranking.append(id) }
            }
        }
        return ranking
    }

    /// Fuses the two rankings with Reciprocal Rank Fusion (rank-based, so the two
    /// scales need no normalizing), blends in recency/frequency via `Ranking`,
    /// drops tombstoned/superseded rows, and returns the result sorted by score.
    private func fuse(
        vectorRanking: [UUID],
        lexicalRanking: [UUID],
        distances: [UUID: Double],
        lexicalIDs: Set<UUID>,
        now: Date
    ) -> [ScoredMemory] {
        let k = 60.0
        var fused: [UUID: Double] = [:]
        for (rank, id) in vectorRanking.enumerated() { fused[id, default: 0] += 1.0 / (k + Double(rank + 1)) }
        for (rank, id) in lexicalRanking.enumerated() { fused[id, default: 0] += 1.0 / (k + Double(rank + 1)) }
        guard let maxRRF = fused.values.max(), maxRRF > 0 else { return [] }

        var scored: [ScoredMemory] = []
        for (id, rrf) in fused {
            guard let memory = fetch(id: id), memory.deletedAt == nil, memory.supersededBy == nil else { continue }
            let relevance = rrf / maxRRF
            let score = Ranking.score(relevance: relevance, memory: memory, now: now)
            scored.append(ScoredMemory(
                memory: memory,
                distance: distances[id] ?? .greatestFiniteMagnitude,
                lexicalMatch: lexicalIDs.contains(id),
                relevance: relevance,
                score: score
            ))
        }
        scored.sort { $0.score > $1.score }
        return scored
    }

    /// Fetches a single memory by id (including tombstoned ones; callers filter).
    /// Returns nil both for "no such row" and on a thrown SQLite error — but a
    /// genuine error (corruption, busy-timeout) is logged to stderr first so a
    /// transient failure isn't silently indistinguishable from "not found".
    public func fetch(id: UUID) -> Memory? {
        do {
            return try fetchRow(id: id)
        } catch {
            FileHandle.standardError.write(Data("engram: fetch(id: \(id.uuidString)) failed: \(error)\n".utf8))
            return nil
        }
    }

    private func fetchRow(id: UUID) throws -> Memory? {
        try db.prepare(
            """
            SELECT m.content, m.source, m.created_at, m.updated_at, m.last_accessed_at, m.access_count, m.deleted_at,
                   (SELECT group_concat(tag, ',') FROM memory_tags WHERE memory_id = m.id),
                   m.verifiability, m.check_anchor, m.verified_at, m.confidence, m.superseded_by, m.evolution_reason, m.title
            FROM memories m WHERE m.id = ?;
            """
        ) { stmt in
            stmt.bind(id.uuidString, at: 1)
            guard try stmt.step() else { return nil }
            let tags = (stmt.columnText(7) ?? "").split(separator: ",").map(String.init)
            let verifiability = stmt.columnText(8).flatMap(Verifiability.init(rawValue:)) ?? .userConfirmOnly
            return Memory(
                id: id,
                title: stmt.columnText(14),
                content: stmt.columnText(0) ?? "",
                tags: tags,
                source: stmt.columnText(1),
                createdAt: Date(timeIntervalSince1970: stmt.columnDouble(2) ?? 0),
                updatedAt: Date(timeIntervalSince1970: stmt.columnDouble(3) ?? 0),
                lastAccessedAt: stmt.columnDouble(4).map { Date(timeIntervalSince1970: $0) },
                accessCount: stmt.columnInt(5),
                deletedAt: stmt.columnDouble(6).map { Date(timeIntervalSince1970: $0) },
                verifiability: verifiability,
                checkAnchor: stmt.columnText(9),
                verifiedAt: stmt.columnDouble(10).map { Date(timeIntervalSince1970: $0) },
                confidence: stmt.columnDouble(11) ?? 1.0,
                supersededBy: stmt.columnText(12).flatMap(UUID.init(uuidString:)),
                evolutionReason: stmt.columnText(13)
            )
        }
    }

    /// Lists active memories most-recently-created first (for the app's browser).
    public func list(limit: Int = 100, includeDeleted: Bool = false) throws -> [Memory] {
        let filter = includeDeleted ? "" : "WHERE deleted_at IS NULL AND superseded_by IS NULL"
        var ids: [UUID] = []
        try db.prepare("SELECT id FROM memories \(filter) ORDER BY created_at DESC LIMIT ?;") { stmt in
            stmt.bind(Int64(limit), at: 1)
            while try stmt.step() {
                if let s = stmt.columnText(0), let id = UUID(uuidString: s) { ids.append(id) }
            }
        }
        return ids.compactMap { fetch(id: $0) }
    }

    /// Every memory in the store, newest first — including superseded and
    /// soft-deleted (tombstoned) rows — for full data portability (`engram
    /// export`). Unlike `list`, this filters nothing and is uncapped, so the user
    /// can get all of their history out. Embedding vectors are intentionally
    /// omitted; content + metadata is the portable data (vectors are derived).
    public func exportAll() throws -> [Memory] {
        var ids: [UUID] = []
        try db.prepare("SELECT id FROM memories ORDER BY created_at DESC;") { stmt in
            while try stmt.step() {
                if let s = stmt.columnText(0), let id = UUID(uuidString: s) { ids.append(id) }
            }
        }
        return ids.compactMap { fetch(id: $0) }
    }

    /// Lists active memories ordered by descending rot-risk (ADR 0008). Classes
    /// excluded from auto-verification (`userConfirmOnly`/`timeless`) score ≈ 0 and
    /// so sink to the bottom.
    public func listByRisk(limit: Int = 100) async throws -> [Memory] {
        let active = try list()
        let now = Date()
        return active
            .sorted { Ranking.rotRisk(for: $0, now: now) > Ranking.rotRisk(for: $1, now: now) }
            .prefix(limit)
            .map { $0 }
    }

    /// Embedding vectors for the most recent active memories, paired with their
    /// ids — for client-side hierarchical clustering (ADR 0011). Decodes the
    /// little-endian float32 blobs stored for sqlite-vec.
    public func embeddingVectors(limit: Int = 200) throws -> [(id: UUID, vector: [Float])] {
        let activeIDs = Set(try list(limit: limit).map(\.id))
        var result: [(id: UUID, vector: [Float])] = []
        try db.prepare("SELECT memory_id, embedding FROM vec_memories;") { stmt in
            while try stmt.step() {
                guard let text = stmt.columnText(0), let id = UUID(uuidString: text),
                      activeIDs.contains(id), let blob = stmt.columnBlob(1) else { continue }
                result.append((id: id, vector: Self.decodeFloats(blob)))
            }
        }
        return result
    }

    /// Nearest semantic neighbours of an existing memory, by sqlite-vec cosine KNN
    /// (ADR 0018 find-similar). Returns up to `limit` other memory ids, closest
    /// first, excluding the memory itself; empty if it has no stored embedding.
    public func neighbors(of id: UUID, limit: Int = 6) throws -> [UUID] {
        var vector: [Float]?
        try db.prepare("SELECT embedding FROM vec_memories WHERE memory_id = ?;") { stmt in
            stmt.bind(id.uuidString, at: 1)
            if try stmt.step(), let blob = stmt.columnBlob(0) {
                vector = Self.decodeFloats(blob)
            }
        }
        guard let vector else { return [] }
        let candidates = try semanticCandidates(for: vector, limit: limit + 1)
        return Array(candidates.ranking.filter { $0 != id }.prefix(limit))
    }

    /// Decodes little-endian float32 bytes (the `floatBlob` encoding) into floats.
    private static func decodeFloats(_ bytes: [UInt8]) -> [Float] {
        let count = bytes.count / 4
        return (0..<count).map { index in
            let offset = index * 4
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    // MARK: - Graph

    /// Builds the memory graph (ADR 0007): gathers each active memory's nearest
    /// semantic neighbours, then hands the per-node neighbour lists to the pure
    /// `MemoryGraphBuilder.blend` for all edge math.
    public func graph(config: GraphConfig = .default) async throws -> MemoryGraph {
        let memories = try list(limit: 5000)
        var neighbors: [UUID: [(id: UUID, distance: Double)]] = [:]
        for memory in memories {
            let vector = try embedder.vector(for: memory.content)
            // +1 so the candidate set still has neighboursPerNode entries after
            // dropping the memory's own self-match (distance 0 to itself).
            let candidates = try semanticCandidates(for: vector, limit: config.neighborsPerNode + 1)
            neighbors[memory.id] = candidates.ranking
                .filter { $0 != memory.id }
                .prefix(config.neighborsPerNode)
                .map { (id: $0, distance: candidates.distances[$0] ?? .greatestFiniteMagnitude) }
        }
        let edges = MemoryGraphBuilder.blend(memories: memories, neighbors: neighbors, config: config)
        return MemoryGraph(nodes: memories.map(GraphNode.init(memory:)), edges: edges)
    }

    // MARK: - Verification

    /// Runs cheap deterministic (non-LLM) checks over all active memories,
    /// resolving each memory's repo root as `~/dev/<source>` and probing the
    /// real filesystem. See `Verifier`.
    public func verify() async throws -> [MemoryVerdict] {
        let memories = try list()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()
        return memories.map { memory in
            let repoRoot = memory.source.map { home.appendingPathComponent("dev/\($0)") }
            return Verifier.verdict(
                for: memory,
                repoRoot: repoRoot,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                branchExists: { Self.gitBranchExists($0, in: repoRoot) },
                now: now
            )
        }
    }

    /// Returns whether a local git branch exists in `repoRoot` (no network).
    /// A nil repo root, any error launching git, or a hang past `timeout` is
    /// treated as "not found". Public + the single source of truth so the CLI's
    /// `verify-context` hook reuses it rather than re-spawning git inline (P2 #7).
    public static func gitBranchExists(_ name: String, in repoRoot: URL?, timeout: TimeInterval = 3) -> Bool {
        guard let repoRoot else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git", "-C", repoRoot.path,
            "rev-parse", "--verify", "--quiet", "refs/heads/\(name)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Watchdog: a git hung on a network filesystem / index lock must not
            // block verify. Terminate past the deadline and treat it as not-found.
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                finished.signal()
            }
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Stats

    public func stats() throws -> MemoryStats {
        var stats = MemoryStats()
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970

        try db.prepare("SELECT count(*) FROM memories WHERE deleted_at IS NULL AND superseded_by IS NULL;") { s in
            _ = try s.step(); stats.totalActive = s.columnInt(0)
        }
        try db.prepare("SELECT count(*) FROM memories WHERE deleted_at IS NOT NULL;") { s in
            _ = try s.step(); stats.totalDeleted = s.columnInt(0)
        }
        try db.prepare("SELECT count(*) FROM events WHERE kind='created' AND at >= ?;") { s in
            s.bind(weekAgo, at: 1); _ = try s.step(); stats.createdLast7Days = s.columnInt(0)
        }
        try db.prepare("SELECT count(*) FROM events WHERE kind='accessed' AND at >= ?;") { s in
            s.bind(weekAgo, at: 1); _ = try s.step(); stats.accessedLast7Days = s.columnInt(0)
        }
        try db.prepare("SELECT coalesce(sum(access_count),0) FROM memories;") { s in
            _ = try s.step(); stats.totalAccesses = s.columnInt(0)
        }
        try db.prepare(
            """
            SELECT t.tag, count(*) c FROM memory_tags t
            JOIN memories m ON m.id = t.memory_id AND m.deleted_at IS NULL AND m.superseded_by IS NULL
            GROUP BY t.tag ORDER BY c DESC LIMIT 10;
            """
        ) { s in
            while try s.step() {
                if let tag = s.columnText(0) { stats.topTags.append((tag, s.columnInt(1))) }
            }
        }
        stats.databaseBytes = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? Int64) ?? 0
        return stats
    }

    // MARK: - Private helpers

    /// Trims a candidate title, strips a leading Markdown `#` heading marker, and
    /// collapses blank input to nil so untitled memories fall back to their
    /// content's first line (ADR 0014).
    private static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let cleaned = title
            .drop { $0 == "#" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Inserts a memory's row (no tags/vector/FTS/event). Must run inside a
    /// transaction; shared by `store` and `supersede`.
    private func insertMemoryRow(_ memory: Memory) throws {
        try db.prepare(
            """
            INSERT INTO memories(id, title, content, source, created_at, updated_at, last_accessed_at, access_count, deleted_at,
                verifiability, check_anchor, verified_at, confidence, superseded_by, evolution_reason)
            VALUES(?, ?, ?, ?, ?, ?, NULL, 0, NULL, ?, ?, NULL, ?, NULL, NULL);
            """
        ) { stmt in
            stmt.bind(memory.id.uuidString, at: 1)
                .bind(memory.title, at: 2)
                .bind(memory.content, at: 3)
                .bind(memory.source, at: 4)
                .bind(memory.createdAt.timeIntervalSince1970, at: 5)
                .bind(memory.updatedAt.timeIntervalSince1970, at: 6)
                .bind(memory.verifiability.rawValue, at: 7)
                .bind(memory.checkAnchor, at: 8)
                .bind(memory.confidence, at: 9)
            _ = try stmt.step()
        }
    }

    private func insertTags(_ tags: [String], for id: UUID) throws {
        for tag in tags {
            try db.prepare("INSERT OR IGNORE INTO memory_tags(memory_id, tag) VALUES(?, ?);") { stmt in
                stmt.bind(id.uuidString, at: 1).bind(tag, at: 2); _ = try stmt.step()
            }
        }
    }

    private func insertVector(_ vector: [Float], for id: UUID) throws {
        try db.prepare("INSERT INTO vec_memories(memory_id, embedding) VALUES(?, ?);") { stmt in
            stmt.bind(id.uuidString, at: 1).bindBlob(Self.floatBlob(vector), at: 2); _ = try stmt.step()
        }
    }

    private func insertFTS(content: String, tags: [String], for id: UUID) throws {
        try db.prepare("INSERT INTO memories_fts(memory_id, content, tags) VALUES(?, ?, ?);") { stmt in
            stmt.bind(id.uuidString, at: 1).bind(content, at: 2).bind(tags.joined(separator: " "), at: 3)
            _ = try stmt.step()
        }
    }

    private func deleteFTS(for id: UUID) throws {
        try db.prepare("DELETE FROM memories_fts WHERE memory_id = ?;") { stmt in
            stmt.bind(id.uuidString, at: 1); _ = try stmt.step()
        }
    }

    /// Turns arbitrary user text into a safe FTS5 MATCH expression: keep
    /// alphanumeric tokens that aren't stopwords, OR them together. Single-char
    /// tokens are kept (only stopwords like "a"/"i" are dropped) so a one-letter
    /// identifier or symbol query still has a lexical leg instead of falling back
    /// to semantic-only (P2 #9). Returns nil if there are no usable tokens.
    static func ftsMatchExpression(for query: String) -> String? {
        let tokens = RecallText.tokens(query)
        guard !tokens.isEmpty else { return nil }
        // Quote each token so FTS5 treats it as a literal (no operator parsing).
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    private func recordEvent(_ kind: EventKind, for id: UUID) throws {
        try db.prepare("INSERT INTO events(memory_id, kind, at) VALUES(?, ?, ?);") { stmt in
            stmt.bind(id.uuidString, at: 1).bind(kind.rawValue, at: 2).bind(Date().timeIntervalSince1970, at: 3)
            _ = try stmt.step()
        }
    }

    private func markAccessed(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try db.exec("BEGIN;")
        do {
            for id in ids {
                try db.prepare("UPDATE memories SET access_count = access_count + 1, last_accessed_at = ? WHERE id = ?;") { stmt in
                    stmt.bind(now, at: 1).bind(id.uuidString, at: 2); _ = try stmt.step()
                }
                try recordEvent(.accessed, for: id)
            }
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Retrieval activity (ADR 0015)

    /// Longest query/prompt stored per retrieval row — bounds table growth while
    /// keeping enough of the prompt to be useful in the activity timeline.
    private static let maxRetrievalQueryLength = 500

    /// Records that `memoryIDs` were surfaced via `source`, with the optional
    /// `query` that surfaced them. One row per id, single timestamp, in a
    /// transaction. Deliberately does **not** touch `access_count` — this ledger
    /// is decoupled from ranking (ADR 0015 preserves ADR 0005's loop-break).
    public func recordRetrieval(memoryIDs: [UUID], source: RetrievalSource, query: String? = nil, sessionID: String? = nil) throws {
        guard !memoryIDs.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let trimmedQuery = query.map { String($0.prefix(Self.maxRetrievalQueryLength)) }
        try db.exec("BEGIN;")
        do {
            for id in memoryIDs {
                try db.prepare("INSERT INTO retrievals(memory_id, source, query, at, session_id) VALUES(?, ?, ?, ?, ?);") { stmt in
                    stmt.bind(id.uuidString, at: 1).bind(source.rawValue, at: 2).bind(trimmedQuery, at: 3)
                        .bind(now, at: 4).bind(sessionID, at: 5)
                    _ = try stmt.step()
                }
            }
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    /// Memories already injected via `recall` in this session within `cooldown`
    /// (ADR 0023). The recall hook drops these post-gate so the same memory isn't
    /// re-injected on every on-topic prompt of a session. Returns an empty set for
    /// an empty `sessionID` (e.g. a manual `fetch` with no session) so nothing is
    /// ever suppressed outside a real session.
    public func recentlyInjectedInSession(_ memoryIDs: [UUID], sessionID: String, within cooldown: TimeInterval) throws -> Set<UUID> {
        guard !sessionID.isEmpty, !memoryIDs.isEmpty else { return [] }
        let cutoff = Date().timeIntervalSince1970 - cooldown
        var suppressed = Set<UUID>()
        let placeholders = memoryIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT DISTINCT memory_id FROM retrievals
            WHERE session_id = ? AND source = ? AND at >= ? AND memory_id IN (\(placeholders));
            """
        try db.prepare(sql) { stmt in
            stmt.bind(sessionID, at: 1).bind(RetrievalSource.recall.rawValue, at: 2).bind(cutoff, at: 3)
            for (offset, id) in memoryIDs.enumerated() { stmt.bind(id.uuidString, at: Int32(4 + offset)) }
            while try stmt.step() {
                if let text = stmt.columnText(0), let id = UUID(uuidString: text) { suppressed.insert(id) }
            }
        }
        return suppressed
    }

    /// Cooldown for re-injecting the same memory via recall within one session
    /// (ADR 0023). 30 minutes: short on-topic sessions show a memory once; a long
    /// session gets at most a periodic refresh rather than the same note every prompt.
    public static let recallReinjectionCooldown: TimeInterval = 30 * 60

    /// Retrieval-activity rows from `since` onward, newest first, optionally
    /// filtered to one `source`. Powers `engram activity` and the Activity view.
    public func retrievals(since: Date, source: RetrievalSource? = nil, limit: Int = 500) throws -> [RetrievalEvent] {
        let sinceTimestamp = since.timeIntervalSince1970
        let sql = """
            SELECT id, memory_id, source, query, at FROM retrievals
            WHERE at >= ?\(source == nil ? "" : " AND source = ?")
            ORDER BY at DESC LIMIT ?;
            """
        var events: [RetrievalEvent] = []
        try db.prepare(sql) { stmt in
            stmt.bind(sinceTimestamp, at: 1)
            if let source {
                stmt.bind(source.rawValue, at: 2).bind(Int64(limit), at: 3)
            } else {
                stmt.bind(Int64(limit), at: 2)
            }
            while try stmt.step() {
                guard let memoryText = stmt.columnText(1), let memoryID = UUID(uuidString: memoryText),
                      let sourceValue = stmt.columnText(2).flatMap(RetrievalSource.init(rawValue:)),
                      let at = stmt.columnDouble(4) else { continue }
                events.append(RetrievalEvent(
                    id: stmt.columnInt(0),
                    memoryID: memoryID,
                    source: sourceValue,
                    query: stmt.columnText(3),
                    at: Date(timeIntervalSince1970: at)
                ))
            }
        }
        return events
    }

    /// The unified Activity timeline (ADR 0020): retrievals (reads) merged with the
    /// write rows of the `events` ledger (`created`/`updated`/`deleted` — never
    /// `accessed`, which overlaps reads and is ranking-coupled), newest first.
    /// `id` is ledger-prefixed so the two tables' rowids stay unique.
    public func activity(since: Date, limit: Int = 500) throws -> [ActivityEvent] {
        let sinceTimestamp = since.timeIntervalSince1970
        let sql = """
            SELECT 'r' AS ledger, id, memory_id, source AS kind, query, at FROM retrievals
                WHERE at >= ?
            UNION ALL
            SELECT 'e' AS ledger, id, memory_id, kind, NULL, at FROM events
                WHERE at >= ? AND kind IN ('created', 'updated', 'deleted')
            ORDER BY at DESC LIMIT ?;
            """
        var events: [ActivityEvent] = []
        try db.prepare(sql) { stmt in
            stmt.bind(sinceTimestamp, at: 1).bind(sinceTimestamp, at: 2).bind(Int64(limit), at: 3)
            while try stmt.step() {
                guard let ledger = stmt.columnText(0),
                      let memoryText = stmt.columnText(2), let memoryID = UUID(uuidString: memoryText),
                      let kindText = stmt.columnText(3),
                      let at = stmt.columnDouble(5) else { continue }
                // Reads map from `RetrievalSource`, writes from `EventKind` (verbs);
                // an unmapped/`accessed` row is skipped.
                let kind: ActivityKind?
                switch ledger {
                case "r": kind = RetrievalSource(rawValue: kindText).map(ActivityKind.init(retrieval:))
                default: kind = EventKind(rawValue: kindText).flatMap(ActivityKind.init(event:))
                }
                guard let kind else { continue }
                events.append(ActivityEvent(
                    id: "\(ledger):\(stmt.columnInt(1))",
                    memoryID: memoryID,
                    kind: kind,
                    query: stmt.columnText(4),
                    at: Date(timeIntervalSince1970: at)
                ))
            }
        }
        return events
    }

    /// Encodes a float vector as little-endian float32 bytes for sqlite-vec.
    private static func floatBlob(_ vector: [Float]) -> [UInt8] {
        vector.withUnsafeBytes { Array($0) }
    }
}
