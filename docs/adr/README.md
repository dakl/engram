# Architecture Decision Records

Significant architectural decisions for Engram are recorded here as ADRs, using
the [Nygard format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions.html).

Each ADR is immutable once Accepted — to change a decision, write a new ADR that
supersedes the old one (and update the old one's status to `Superseded by NNNN`).

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-memory-integration-strategy.md) | Memory integration strategy: gated automatic recall + model-driven store | Accepted (recall surface superseded by 0005) |
| [0002](0002-keep-docs-in-sync.md) | Keep documentation in sync with the code | Accepted |
| [0003](0003-mac-app-distribution-model.md) | Mac app distribution: non-sandboxed dev-tool that installs the CLI/hooks/skills | Accepted |
| [0004](0004-hybrid-retrieval.md) | Hybrid retrieval: lexical (FTS5/BM25) + semantic (sqlite-vec), fused with RRF | Accepted (embedder superseded by 0012) |
| [0005](0005-recall-via-gated-per-request-hook.md) | Recall via a gated, read-only, per-request hook (no /recall skill) | Accepted (gate criteria refined by 0021) |
| [0006](0006-storage-concurrency-model.md) | Storage concurrency model: `MemoryStore` as an `actor` | Accepted |
| [0007](0007-memory-graph-view.md) | Memory graph: one derived graph + community hierarchy, three read-only views | Accepted (layout engine superseded by 0009; view enumeration by 0011) |
| [0008](0008-memory-verification-decay.md) | Memory verification & decay subsystem (the `/dream` design) | Accepted |
| [0009](0009-hand-rolled-force-layout.md) | Hand-rolled force-directed layout instead of Grape (supersedes 0007 layout engine) | Accepted |
| [0010](0010-app-updates-via-sparkle.md) | In-app updates via Sparkle, released from the public engram repo | Accepted |
| [0011](0011-interactive-graph-exploration.md) | Interactive multi-lens graph exploration + warm adaptive theme | Superseded by 0018 (Map+Structure replace Tree/Graph); warm theme scoped to canvas by 0016 |
| [0012](0012-contextual-embeddings.md) | On-device contextual embeddings via NLContextualEmbedding (supersedes 0004's embedder) | Accepted |
| [0013](0013-faceted-tags.md) | Faceted tags: reserved `key:value` convention over flat tags | Accepted |
| [0014](0014-display-titles.md) | Authored display titles, model-written at store time | Accepted |
| [0015](0015-retrieval-activity-tracking.md) | Retrieval activity tracking: a dedicated, ranking-decoupled ledger | Accepted (Activity view extended by 0020) |
| [0016](0016-native-navigationsplitview-shell.md) | Native shell: NavigationSplitView + toolbar + inspector, system palette | Accepted |
| [0017](0017-native-tree-outline-activity-table.md) | Native lens internals: outline Tree + Table Activity (supersedes 0011 dendrogram) | Accepted (Tree superseded by 0018) |
| [0018](0018-collection-exploration-map-and-structure.md) | Collection exploration: Semantic Map + Structure lens (supersedes 0011 + 0017 Tree/Graph) | Accepted (Map/Structure superseded by 0019) |
| [0019](0019-tag-centric-exploration.md) | Tag-centric exploration: Tags list + bipartite tag-graph (supersedes 0018 Map/Structure) | Accepted |
| [0020](0020-unified-activity-timeline.md) | Unified Activity timeline: reads + writes in one stream (extends 0015) | Accepted |
| [0021](0021-embedder-relative-recall-gate.md) | Embedder-relative recall gate, calibrated by offline eval (refines 0005's gate) | Accepted |
| [0022](0022-privileged-helper-for-cli-install.md) | Privileged CLI install via a one-shot authenticated `osascript` | Accepted |
| [0023](0023-session-scoped-recall-cooldown.md) | Session-scoped recall re-injection cooldown (stop re-injecting the same memory every prompt) | Accepted |

## Writing a new ADR

1. Copy the structure of an existing ADR. Number it sequentially (next free `NNNN`).
2. Sections: **Status**, **Date**, **Deciders**, **Context**, **Decision**, **Consequences**.
3. Status starts as `Proposed`, becomes `Accepted` when agreed, or `Superseded by NNNN`.
4. Add a row to the index above.
