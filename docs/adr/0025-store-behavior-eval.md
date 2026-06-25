# 25. LLM-in-the-loop eval for store behavior (does the agent save the right memories?)

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** Daniel Klevebring, Claude
- **Relates to:** ADR 0001 (model-driven store), ADR 0021 (retrieval eval), ADR 0023 (recall metrics)

## Context

Recall quality has an offline gate (ADR 0021's `engram-eval`): deterministic,
free, runs in CI. **Store** quality has had nothing. And storing is the half
that was actually failing in practice — investigation of ~1800 real sessions
found stores effectively stopped after an initial burst while recall kept
firing: a mix of the model not *deciding* to save and, when it did try, fumbling
the CLI invocation (the latter fixed separately by the `engram store`
arg-robustness change). The decision half — "given a session, does the agent
correctly choose to save the durable things and skip the noise?" — is the core
risk for whether Engram accrues anything to recall.

That question can't be answered by a deterministic harness. Storing is
model-driven (ADR 0001): it depends on an LLM reading the reflection nudge / the
`/remember` guidance and choosing to act. Measuring it requires running an
actual model. That makes the eval fundamentally different from `engram-eval`:
non-deterministic, model-dependent, and it costs API tokens.

## Decision

Add a separate **LLM-in-the-loop** harness, `scripts/store_eval.py` (Python +
the `anthropic` SDK, matching `scripts/embeddings_eval.py`), that measures store
**precision/recall** over labeled session fixtures.

- **Fixtures** (`scripts/store_eval_fixtures.json`): short coding-session
  transcripts, each labeled `should_store` (a durable preference / decision /
  project fact / gotcha) or not (routine chatter, transient state, general
  knowledge, repo-derivable facts). Starter set covers both classes incl. an
  explicit "remember this", a fact buried in chatter, and near-miss negatives.
- **Mechanism**: for each fixture, call the model with an `engram_store` tool
  available and the production store signal as the policy (system prompt + the
  recall hook's reflection nudge appended as the final user turn), `tool_choice`
  auto. Whether the model emits an `engram_store` call is its decision; compare
  to the label. We don't execute the tool — we only observe the call.
- **Metrics**: store precision (of what it saved, how much was warranted),
  recall (of what it should have saved, how much it did), plus F1/accuracy and
  the per-fixture stored content for eyeballing quality.
- **Model is a parameter and is recorded.** `--model` (default
  `claude-opus-4-8`); every `--record` run writes
  `eval/store-runs/<ts>-<model>.json` with the git sha, model, a hash of the
  policy, and per-fixture results — so runs are comparable across models and
  across prompt revisions.
- **The policy is the thing under test, and is A/B-able.** The default `POLICY`
  in the harness mirrors production (the nudge + the `/remember` criteria);
  `--policy-file` swaps in a candidate wording. This is how we measure "how good
  are we at *triggering* the agent to store" as we iterate the nudge.
- A dependency-free `validate` subcommand checks the fixtures and prints the
  plan without an API key, so CI / contributors can sanity-check fixtures
  without spending tokens.

## Consequences

- We can finally measure, and regression-test, the store decision — and A/B nudge
  wordings against real model behavior across Opus/Sonnet/Haiku, tracking which
  model each number came from.
- **Not a CI gate.** It costs tokens and is non-deterministic, so it runs
  on-demand (like the embedding-model exploration harness), not on every PR.
  Numbers are a relative A/B, not an absolute benchmark; the small fixture set
  means per-fixture misses matter more than the aggregate.
- **The policy must be kept in sync with production.** The harness embeds a copy
  of the nudge/guidance; if the production reflection nudge (`main.swift`) or the
  `/remember` skill (`Setup.swift`) changes and the harness doesn't, the eval
  stops predicting production. This duplication is the accepted cost of testing
  the prompt as a unit.
- **Fidelity gap.** Production stores via the `/remember` skill through Claude
  Code; the eval uses a single `engram_store` tool call via the API. It measures
  the *decision* faithfully but not the full skill/CLI path (the arg-form
  failures are covered by the deterministic CLI tests instead).
- Token cost scales with fixtures × models × policies; keep the fixture set
  small and curated, and use `--limit` for smoke runs.
