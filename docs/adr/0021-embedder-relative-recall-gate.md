# 21. Embedder-relative recall gate, calibrated by offline eval

- **Status:** Accepted
- **Date:** 2026-06-10
- **Deciders:** Daniel Klevebring, Claude
- **Refines:** the gating criteria in ADR 0005 (the per-request read-only hook
  itself stands unchanged).

## Context

ADR 0005 injects "confident" memories on every `UserPromptSubmit`, gated by *"a
lexical (keyword) hit **or** a tight semantic distance < 0.45, capped at 3"*.
That gate was written when the embedder was the weak static `NLEmbedding`
(ADR 0004), where — as 0005 itself notes — the semantic threshold was dormant and
the lexical hit carried everything. After the upgrade to `NLContextualEmbedding`
(ADR 0012) the gate was never recalibrated, and in practice it injected
off-topic memories on nearly every prompt (costing tokens, as observed in the
Activity view).

To diagnose it rather than guess, we built an offline retrieval eval
(`Sources/engram-eval`, `EngramCore/RetrievalMetrics`): ~150 labeled memories +
58 prompts (targeted / multi / negative), scoring each gate config on gate
recall, injection precision, and negative-prompt false-positive rate. The eval
surfaced three facts:

1. **The lexical leg leaked.** FTS5 ORs query tokens, so `lexicalMatch` was true
   on a *single* shared keyword — coincidental overlap injected unrelated
   memories.
2. **The `0.45` distance ceiling was a no-op for the contextual model.** Its
   cosine distances cluster near ~0.1 (on-topic ≈ 0.099, off-topic ≈ 0.135), so
   `< 0.45` never rejected anything. With it dormant, every negative prompt
   injected 3 memories (100% false-positive rate).
3. **Per-query relevance and distance-margin signals don't separate** on- from
   off-topic; only the *absolute* top-1 distance does.

A threshold sweep showed a ceiling of **~0.10** (with a lexical leg requiring
**≥2** shared tokens) cuts the negative false-positive rate 100% → 13% and nearly
doubles injection precision, while *raising* gate recall (the loose gate's junk
was crowding real answers out of the 3-slot budget).

Crucially, `0.10` is calibrated to the contextual model's distance scale. The
`word-512` fallback (ADR 0012) lives on a different scale, so a single global
constant is unsafe.

## Decision

- **The recall gate is extracted into `EngramCore/RecallGate`** — one
  `RecallGate.select(_:query:config:)` shared by the hook and the eval, with a
  `RecallGateConfig` (top-k, distance ceiling, min lexical-token hits, optional
  relevance floor / median gate). `RecallText` is the shared tokenizer so the
  gate's lexical-overlap count matches the FTS stage.
- **Thresholds are embedder-relative**, chosen by `Embedder.signature` via
  `RecallGate.config(forEmbedderSignature:)`:
  - `contextual-*` → tightened: distance ceiling **0.10**, lexical leg **≥2**
    shared tokens, no relevance floor, no median gate.
  - everything else (the `word-512` fallback) → the prior permissive behavior,
    since its scale isn't calibrated and the fallback is a transient,
    one-launch-until-assets-download state.
- **Calibration is reproducible, not folklore.** `engram-eval` is kept in-repo
  and runnable ad-hoc (`swift run engram-eval`); `--record` appends a per-run
  JSON file under `eval/runs/` carrying the git sha, embedder signature, and host
  alongside the metrics, so future changes are compared on like-for-like runs.
- The gate and metrics logic are covered by deterministic unit tests in
  `make test`; the eval's absolute numbers (embedder/machine-dependent) are not
  asserted.

## Consequences

**Positive**
- Off-topic prompts inject (almost) nothing; injected context is far more often
  relevant; the limited injection budget stops being crowded by coincidental
  keyword hits.
- The gate is now a tested, inspectable unit rather than an inline expression,
  and changes can be measured rather than eyeballed.

**Negative / trade-offs**
- The `0.10` ceiling is embedder-specific; a future embedder swap requires a new
  calibration run (the eval makes this a known, cheap step rather than a guess).
- The fallback embedder keeps the old leaky behavior — acceptable because it's
  transient and degraded by nature; a clean fix is to remove the fallback
  entirely by **bundling our own deterministic embedder** (ROADMAP item; would
  also make the eval reproducible across machines and the threshold a stable
  constant).
