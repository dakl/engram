# 6. Storage concurrency model: `MemoryStore` as an `actor`

- **Status:** Accepted
- **Date:** 2026-06-02
- **Deciders:** Daniel Klevebring

## Context

`MemoryStore` is a `final class` with synchronous methods, holding a non-Sendable
`SQLiteDatabase` and `Embedder`. The CLI uses it on one thread, which is fine.
But the app (`EngramModel`, `@MainActor`) calls it **synchronously on the main
actor** — so a search runs a full embed + hybrid query on the UI thread, and any
move to call it from a background `Task` would be a data race (a single SQLite
connection used concurrently, plus mutable store state).

We want the app to call the store off the main actor without races, while the
CLI keeps working.

## Decision

Make **`MemoryStore` an `actor`**. Its mutable state (the SQLite connection,
embedder) becomes actor-isolated, so the type is `Sendable` and concurrent
callers are serialized automatically — exactly one operation touches the
connection at a time. Cross-actor calls become `async` (callers `await`).

- The **CLI** awaits store calls from `main.swift` top-level code (Swift permits
  top-level `await`); behaviour is unchanged.
- The **app** calls the store from background `Task`s and publishes results back
  to the `@MainActor` view model, so SQLite/embedding work leaves the UI thread.
- **Cross-process** safety (CLI and app are separate processes on one DB file) is
  unchanged — it still rests on SQLite `FULLMUTEX` + `busy_timeout`, not the
  actor. The actor only serializes *within* a process.

### Alternatives rejected
- **Keep by-convention single-threaded use.** Works for the CLI but blocks the
  main thread in the app and is a latent race the moment anything goes async.
- **`@unchecked Sendable` wrapper + a private serial queue.** Achieves
  serialization but opts out of compiler checking and is more code than an actor.

## Consequences

**Positive**
- App can do store I/O off the main actor; no UI-thread blocking; compiler-checked
  data-race safety within the process.

**Negative / trade-offs**
- Store methods are now `async` at call sites — `await` sprinkled through the CLI,
  tests, and the view model.
- Synchronous SQLite calls run on the actor's executor; a long op briefly occupies
  a cooperative thread. Fine for a local single-user DB.
