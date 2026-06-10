import Foundation
import CSQLite

/// Minimal, throwing wrapper around the vendored SQLite C API. Not a general
/// ORM — just enough to prepare statements, bind values, and read rows safely.
final class SQLiteDatabase {
    enum SQLiteError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)
        case bind(String)

        var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .prepare(let m): return "sqlite prepare failed: \(m)"
            case .step(let m): return "sqlite step failed: \(m)"
            case .bind(let m): return "sqlite bind failed: \(m)"
            }
        }
    }

    private let handle: OpaquePointer

    // SQLITE_TRANSIENT tells SQLite to copy bound bytes immediately.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw SQLiteError.open(msg)
        }
        self.handle = db
        // Restrict the store (and its WAL/SHM sidecars, when present) to the owner
        // — defense-in-depth alongside the 0700 support directory, since memories
        // are stored as plaintext. Best-effort; touches perms only, never content.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
        }
        // Register the statically-linked sqlite-vec extension on this connection.
        // With SQLITE_CORE the api-routines pointer is unused, so nil is fine.
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_vec_init(db, &errmsg, nil) == SQLITE_OK else {
            let m = errmsg.map { String(cString: $0) } ?? "vec init failed"
            sqlite3_free(errmsg)
            throw SQLiteError.open(m)
        }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA busy_timeout = 5000;")
    }

    deinit { sqlite3_close(handle) }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs one or more statements with no result rows.
    func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let m = errmsg.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errmsg)
            throw SQLiteError.step(m)
        }
    }

    /// Prepares a statement and hands it to `body` for binding + stepping.
    func prepare<T>(_ sql: String, _ body: (Statement) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        return try body(Statement(stmt: stmt, db: self))
    }

    /// Thin per-statement binder/reader. Bind indices are 1-based, columns 0-based.
    final class Statement {
        private let stmt: OpaquePointer
        private unowned let db: SQLiteDatabase

        init(stmt: OpaquePointer, db: SQLiteDatabase) {
            self.stmt = stmt
            self.db = db
        }

        @discardableResult func bind(_ value: String?, at index: Int32) -> Statement {
            if let value {
                sqlite3_bind_text(stmt, index, value, -1, SQLiteDatabase.transient)
            } else {
                sqlite3_bind_null(stmt, index)
            }
            return self
        }

        @discardableResult func bind(_ value: Double?, at index: Int32) -> Statement {
            if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
            return self
        }

        @discardableResult func bind(_ value: Int64, at index: Int32) -> Statement {
            sqlite3_bind_int64(stmt, index, value)
            return self
        }

        @discardableResult func bindBlob(_ bytes: [UInt8], at index: Int32) -> Statement {
            bytes.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLiteDatabase.transient)
            }
            return self
        }

        /// Steps once. Returns true if a row is available, false when done.
        func step() throws -> Bool {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError.step(db.lastErrorMessage)
            }
        }

        func columnText(_ index: Int32) -> String? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        }

        func columnDouble(_ index: Int32) -> Double? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(stmt, index)
        }

        func columnInt(_ index: Int32) -> Int {
            Int(sqlite3_column_int64(stmt, index))
        }

        /// Raw bytes of a BLOB column, or nil if NULL/empty.
        func columnBlob(_ index: Int32) -> [UInt8]? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
                  let pointer = sqlite3_column_blob(stmt, index) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, index))
            return Array(UnsafeRawBufferPointer(start: pointer, count: count))
        }
    }
}
