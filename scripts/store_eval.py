#!/usr/bin/env python3
"""Store-behavior eval — does the agent decide to save the right memories?

LLM-in-the-loop (ADR 0025). For each labeled session fixture, this runs a model
with an `engram_store` tool available and Engram's production store-reflection
guidance as the policy, then checks whether the model *called* the tool —
comparing its decision against the fixture's `should_store` label. Reports store
**precision / recall** and per-fixture outcomes.

Unlike the Swift `engram-eval` (a deterministic retrieval gate), this calls a
real model: results are model- and prompt-dependent and cost API tokens. Treat
it as a *relative* A/B across models and policy wordings — not an absolute
benchmark. The model id and a hash of the policy are recorded on every run, so
runs are comparable.

The `POLICY` below mirrors the production store signal (the recall hook's
reflection nudge + the /remember guidance). **Keep it in sync** — when the
production nudge wording changes, update it here, or the eval stops predicting
production behavior. To A/B a candidate wording, pass `--policy-file`.

Usage:
  # validate fixtures + print the plan, no API key needed:
  uv run scripts/store_eval.py validate

  # run against a model (needs ANTHROPIC_API_KEY); opus-4-8 is the default:
  uv run --with anthropic scripts/store_eval.py run
  uv run --with anthropic scripts/store_eval.py run --model claude-sonnet-4-6
  uv run --with anthropic scripts/store_eval.py run --record   # → eval/store-runs/<ts>-<model>.json
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

FIXTURES_PATH = Path(__file__).parent / "store_eval_fixtures.json"
RUNS_DIR = Path(__file__).parent.parent / "eval" / "store-runs"
DEFAULT_MODEL = "claude-opus-4-8"

# The policy under test: the system prompt + the final-turn reflection nudge the
# agent sees. This mirrors the production store signal (the recall hook's nudge
# in Sources/engram/main.swift + the /remember guidance in Setup.swift). The
# only deliberate divergence: production saves via the `/remember` skill, here
# the model saves via the `engram_store` tool so the harness can observe the
# decision. Keep the wording in sync with production.
POLICY = {
    "system": (
        "You are an AI assistant pair-working with a developer in a coding session. "
        "You have access to Engram, a long-term memory store, via the `engram_store` "
        "tool. Save durable, reusable knowledge — preferences, decisions, project "
        "facts, and gotchas — that would help in future sessions. Do NOT save routine "
        "task chatter, transient state, general knowledge, or anything already captured "
        "in the repo or git history. If nothing durable surfaced, simply don't call the "
        "tool."
    ),
    "nudge": (
        "Engram reflection check: glance back over the recent turns. If something "
        "durable surfaced — a preference, a decision, a project fact, or a gotcha you'd "
        "want recalled weeks from now — save it with the engram_store tool. Only save "
        "what's genuinely reusable; skip routine task chatter and anything already in "
        "the repo or git history. Nothing notable? Don't call the tool."
    ),
}

ENGRAM_STORE_TOOL = {
    "name": "engram_store",
    "description": (
        "Save a durable memory to Engram for recall in future sessions. Call this only "
        "when something genuinely reusable surfaced — a preference, decision, project "
        "fact, or gotcha worth recalling weeks later."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "content": {
                "type": "string",
                "description": "The memory as a short Markdown note (a one-line title then the fact).",
            },
            "tags": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["content"],
        "additionalProperties": False,
    },
}


def _load_fixtures() -> list[dict]:
    data = json.loads(FIXTURES_PATH.read_text())
    return data["fixtures"]


def _policy(policy_file: str | None) -> dict:
    if policy_file is None:
        return POLICY
    loaded = json.loads(Path(policy_file).read_text())
    if "system" not in loaded or "nudge" not in loaded:
        raise SystemExit(f"policy file {policy_file} must define 'system' and 'nudge'")
    return loaded


def _policy_hash(policy: dict) -> str:
    blob = json.dumps([policy["system"], policy["nudge"], ENGRAM_STORE_TOOL], sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()[:12]


def _git_sha() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def _build_messages(fixture: dict, policy: dict) -> list[dict]:
    # The fixture transcript, then the reflection nudge as the final user turn —
    # consecutive user turns are fine (the API merges them).
    return [*fixture["messages"], {"role": "user", "content": policy["nudge"]}]


def validate() -> None:
    """Check the fixtures are well-formed and print the run plan. No API calls."""
    fixtures = _load_fixtures()
    ids = [f["id"] for f in fixtures]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate fixture ids")
    for f in fixtures:
        for key in ("id", "should_store", "messages", "rationale"):
            if key not in f:
                raise SystemExit(f"fixture {f.get('id', '?')} missing '{key}'")
        if not f["messages"] or f["messages"][0]["role"] != "user":
            raise SystemExit(f"fixture {f['id']}: messages must be non-empty and start with a user turn")
        for m in f["messages"]:
            if m["role"] not in ("user", "assistant"):
                raise SystemExit(f"fixture {f['id']}: bad role {m['role']!r}")

    positives = sum(1 for f in fixtures if f["should_store"])
    print(f"{len(fixtures)} fixtures — {positives} should-store, {len(fixtures) - positives} should-not")
    print(f"policy hash: {_policy_hash(POLICY)}   default model: {DEFAULT_MODEL}")
    print("\nfixtures:")
    for f in fixtures:
        mark = "STORE " if f["should_store"] else "skip  "
        print(f"  [{mark}] {f['id']}: {f['rationale']}")
    print("\nfixtures valid. Run with: uv run --with anthropic scripts/store_eval.py run")


def run(
    model: str = DEFAULT_MODEL,
    limit: int | None = None,
    record: bool = False,
    policy_file: str | None = None,
    thinking: bool = True,
) -> None:
    """Run each fixture through `model` and report store precision/recall.

    model: Claude model id (default claude-opus-4-8).
    limit: only run the first N fixtures (for a cheap smoke run).
    record: append a run JSON under eval/store-runs/.
    policy_file: JSON with {"system","nudge"} to A/B an alternative policy.
    thinking: run with adaptive thinking (mirrors production agents); --no-thinking is cheaper.
    """
    import anthropic  # imported lazily so `validate` needs no SDK / network

    fixtures = _load_fixtures()
    if limit is not None:
        fixtures = fixtures[:limit]
    policy = _policy(policy_file)
    client = anthropic.Anthropic()

    results: list[dict] = []
    for fixture in fixtures:
        kwargs: dict = {
            "model": model,
            "max_tokens": 4096,
            "system": policy["system"],
            "tools": [ENGRAM_STORE_TOOL],
            "messages": _build_messages(fixture, policy),
        }
        if thinking:
            kwargs["thinking"] = {"type": "adaptive"}
        response = client.messages.create(**kwargs)

        store_calls = [
            b.input for b in response.content
            if b.type == "tool_use" and b.name == "engram_store"
        ]
        stored = len(store_calls) > 0
        correct = stored == fixture["should_store"]
        results.append({
            "id": fixture["id"],
            "should_store": fixture["should_store"],
            "stored": stored,
            "correct": correct,
            "stored_content": [c.get("content", "") for c in store_calls],
        })

    metrics = _metrics(results)
    _print_report(results, metrics, model)

    if record:
        RUNS_DIR.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%dT%H-%M-%SZ", time.gmtime())
        out = RUNS_DIR / f"{stamp}-{model}.json"
        out.write_text(json.dumps({
            "git_sha": _git_sha(),
            "model": model,
            "thinking": thinking,
            "policy_hash": _policy_hash(policy),
            "timestamp": stamp,
            "metrics": metrics,
            "results": results,
        }, indent=2))
        print(f"\nrecorded → {out}")


def _metrics(results: list[dict]) -> dict:
    tp = sum(1 for r in results if r["should_store"] and r["stored"])
    fp = sum(1 for r in results if not r["should_store"] and r["stored"])
    fn = sum(1 for r in results if r["should_store"] and not r["stored"])
    tn = sum(1 for r in results if not r["should_store"] and not r["stored"])
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
    return {
        "tp": tp, "fp": fp, "fn": fn, "tn": tn,
        "precision": round(precision, 3),
        "recall": round(recall, 3),
        "f1": round(f1, 3),
        "accuracy": round((tp + tn) / len(results), 3) if results else 0.0,
    }


def _print_report(results: list[dict], metrics: dict, model: str) -> None:
    print(f"\n=== store-behavior eval — {model} ===")
    for r in results:
        verdict = "ok " if r["correct"] else "MISS"
        want = "store" if r["should_store"] else "skip"
        got = "stored" if r["stored"] else "skipped"
        print(f"  [{verdict}] {r['id']:28} want={want:5} got={got}")
        if r["stored"] and r["stored_content"]:
            print(f"          ↳ {r['stored_content'][0][:80]}")
    m = metrics
    print(
        f"\nprecision {m['precision']}  recall {m['recall']}  f1 {m['f1']}  "
        f"accuracy {m['accuracy']}  (tp={m['tp']} fp={m['fp']} fn={m['fn']} tn={m['tn']})"
    )
    print("note: model/prompt-dependent — a relative A/B, not a benchmark.")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    command, rest = args[0], args[1:]
    if command == "validate":
        validate()
    elif command == "run":
        # Minimal flag parsing (kept dependency-free): --key value / --flag / --no-flag.
        opts: dict = {}
        i = 0
        while i < len(rest):
            tok = rest[i]
            if tok.startswith("--no-"):
                opts[tok[5:].replace("-", "_")] = False
                i += 1
            elif tok.startswith("--"):
                key = tok[2:].replace("-", "_")
                if i + 1 < len(rest) and not rest[i + 1].startswith("--"):
                    opts[key] = rest[i + 1]
                    i += 2
                else:
                    opts[key] = True
                    i += 1
            else:
                i += 1
        if "limit" in opts and opts["limit"] is not True:
            opts["limit"] = int(opts["limit"])
        run(**opts)
    else:
        raise SystemExit(f"unknown command {command!r} — use 'validate' or 'run'")
