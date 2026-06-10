# 9. Hand-rolled force-directed layout instead of Grape

- **Status:** Accepted
- **Date:** 2026-06-03
- **Deciders:** Daniel Klevebring
- **Supersedes:** the "Force-layout: third-party engine behind our own protocol"
  section of [ADR 0007](0007-memory-graph-view.md) (the Grape dependency). The
  rest of ADR 0007 (derived graph, Louvain, three views, `GraphLayoutEngine`
  protocol) stands.

## Context

ADR 0007 chose **Grape**'s `ForceSimulation` module for the force physics,
behind a `GraphLayoutEngine` protocol. Implementing G3 surfaced a blocking
constraint in Grape 1.1.0:

- The **`ForceSimulation` product exposes no public way to read node positions** —
  `Kinetics.position` is `package`-level, `positionBufferPointer` is commented
  out. Without positions there is nothing to render.
- Positions are public **only** in the higher-level **`Grape`** module
  (`SimulationContext.position`), which is tied to Grape's SwiftUI
  `ForceDirectedGraph` view — **the exact coupling ADR 0007 explicitly rejected**
  ("forecloses the hand-rolled option that was explicitly wanted").
- The only `ForceSimulation`-only escape was `Mirror` reflection into the
  package-private buffer — brittle, breaks on any Grape update, runtime-unverified.

ADR 0007 already named **"a hand-rolled spring sim"** as the swappable
alternative, and the project's ethos is vendor-everything / dependency-averse.

## Decision

**Drop the Grape dependency. Hand-roll a small spring-electrical (force-directed)
layout** in the app, conforming to the unchanged `GraphLayoutEngine` protocol
(`step()` / `positions` / `isSettled`):

- Spring attraction along edges, Coulomb-style repulsion between nodes, mild
  centering; cooling `alpha` that decays per tick; `isSettled` when `alpha`
  drops below a threshold (or a max-tick cap) so the view can freeze.
- Pure Swift, in the app layer, no third-party dependency, fully testable.
- The protocol stays, so a tuned engine (Barnes–Hut, or Grape if it later
  exposes positions) can be swapped back in without touching the rendering or
  `MemoryGraph`.

## Consequences

**Positive**
- No dependency, no reflection hack; full control; deterministic + testable.
- Matches the project's vendor-everything style; one fewer supply-chain pin.

**Negative / trade-offs**
- Naïve repulsion is O(n²) per tick (vs Grape's Barnes–Hut). Fine at hundreds of
  nodes; if the store grows large, add spatial partitioning or revisit a tuned
  engine behind the same protocol.
- We own the layout quality/tuning instead of borrowing Grape's.
