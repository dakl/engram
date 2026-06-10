#!/usr/bin/env python3
"""
Compute code quality metrics for the Handla Swift project.

Produces metrics/quality.json with full per-file and per-function data
plus distribution stats (mean, max, p50/p75/p90) for trend tracking.
No hard thresholds — /deslop defines its own.

Usage:
    make metrics                  # compute and write metrics/quality.json
    make metrics-push             # compute + push to wandb
    uv run --with lizard scripts/metrics.py [--use-wandb]
"""

import argparse
import csv
import io
import json
import os
import shutil
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).parent.parent
# Engram's Swift lives in two trees: the SwiftPM package (Sources/, Tests/) and
# the Xcode app (Engram/). rglob("*.swift") skips the vendored C under
# Sources/CSQLite naturally.
SWIFT_ROOTS = [REPO_ROOT / "Sources", REPO_ROOT / "Tests", REPO_ROOT / "Engram"]
OUTPUT_PATH = REPO_ROOT / "metrics" / "quality.json"

WANDB_PROJECT = os.environ.get("WANDB_PROJECT", "engram-code-metrics")
WANDB_ENTITY = os.environ.get("WANDB_ENTITY")  # set to your own wandb entity to push

HOTSPOTS_COUNT = 5


def classify_files(roots: list[Path]) -> tuple[list[Path], list[Path]]:
    all_swift: list[Path] = []
    for root in roots:
        if root.exists():
            all_swift.extend(root.rglob("*.swift"))
    test_files = [
        f for f in all_swift
        if any("Tests" in part for part in f.parts)
    ]
    code_files = [f for f in all_swift if f not in test_files]
    return code_files, test_files


def count_lines_file(path: Path) -> dict[str, int]:
    total = 0
    blank = 0
    comment = 0
    in_block_comment = False

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        total += 1

        if not line:
            blank += 1
            continue

        if in_block_comment:
            comment += 1
            if "*/" in line:
                in_block_comment = False
            continue

        if line.startswith("//"):
            comment += 1
        elif line.startswith("/*"):
            comment += 1
            if "*/" not in line[2:]:
                in_block_comment = True
        else:
            if "/*" in line:
                in_block_comment = True

    return {"total": total, "code": total - blank - comment, "comment": comment, "blank": blank}


def count_lines(files: list[Path]) -> dict[str, int]:
    totals: dict[str, int] = {"total": 0, "code": 0, "comment": 0, "blank": 0}
    for path in files:
        for key, value in count_lines_file(path).items():
            totals[key] += value
    return totals


def percentile(sorted_values: list[float], p: float) -> float:
    n = len(sorted_values)
    if n == 0:
        return 0.0
    index = (p / 100) * (n - 1)
    lower = int(index)
    upper = min(lower + 1, n - 1)
    return round(sorted_values[lower] + (index - lower) * (sorted_values[upper] - sorted_values[lower]), 1)


def distribution(values: list[float]) -> dict:
    if not values:
        return {"count": 0, "mean": 0.0, "max": 0.0, "p50": 0.0, "p75": 0.0, "p90": 0.0}
    sorted_values = sorted(values)
    return {
        "count": len(values),
        "mean": round(sum(values) / len(values), 1),
        "max": float(max(values)),
        "p50": percentile(sorted_values, 50),
        "p75": percentile(sorted_values, 75),
        "p90": percentile(sorted_values, 90),
    }


def run_lizard(files: list[Path]) -> list[dict]:
    if not files:
        return []

    result = subprocess.run(
        ["uv", "run", "--with", "lizard", "lizard", "--csv", *[str(f) for f in files]],
        capture_output=True,
        text=True,
    )

    # lizard --csv header: NLOC,CCN,token_count,param_count,length,location,file,method,start_line,end_line
    functions: list[dict] = []
    reader = csv.reader(io.StringIO(result.stdout))
    for parts in reader:
        if len(parts) < 8 or not parts[0].strip().isdigit():
            continue
        functions.append({
            "nloc": int(parts[0]),
            "ccn": int(parts[1]),
            "tokens": int(parts[2]),
            "params": int(parts[3]),
            "length": int(parts[4]),
            "file": Path(parts[6]).name,
            "method": parts[7].strip(),
        })
    return functions


def compute_hotspots(functions: list[dict]) -> dict:
    def slim(f: dict) -> dict:
        return {"file": f["file"], "method": f["method"], "ccn": f["ccn"], "length": f["length"]}

    by_complexity = sorted(functions, key=lambda f: f["ccn"], reverse=True)[:HOTSPOTS_COUNT]
    by_length = sorted(functions, key=lambda f: f["length"], reverse=True)[:HOTSPOTS_COUNT]
    return {
        "by_complexity": [slim(f) for f in by_complexity],
        "by_length": [slim(f) for f in by_length],
    }


def run_swiftlint(files: list[Path]) -> dict | None:
    if not shutil.which("swiftlint") or not files:
        return None

    result = subprocess.run(
        ["swiftlint", "lint", "--reporter", "json", *[str(f) for f in files]],
        capture_output=True,
        text=True,
    )

    try:
        violations: list[dict] = json.loads(result.stdout)
    except (json.JSONDecodeError, ValueError):
        return None

    by_rule: dict[str, int] = {}
    for violation in violations:
        rule_id: str = violation.get("rule_id", "unknown")
        by_rule[rule_id] = by_rule.get(rule_id, 0) + 1

    return {
        "total_violations": len(violations),
        "warnings": sum(1 for v in violations if v.get("severity") == "Warning"),
        "errors": sum(1 for v in violations if v.get("severity") == "Error"),
        "by_rule": dict(sorted(by_rule.items(), key=lambda x: x[1], reverse=True)),
    }


def compute_group_metrics(files: list[Path]) -> dict:
    all_functions = run_lizard(files)
    lint = run_swiftlint(files)

    functions_by_file: dict[str, list[dict]] = {}
    for f in all_functions:
        functions_by_file.setdefault(f["file"], []).append(f)

    by_file = []
    for path in sorted(files):
        file_functions = functions_by_file.get(path.name, [])
        entry: dict = {
            "file": path.name,
            "lines": count_lines_file(path),
            "functions": [
                {"method": f["method"], "ccn": f["ccn"], "length": f["length"], "nloc": f["nloc"]}
                for f in file_functions
            ],
        }
        by_file.append(entry)

    result: dict = {
        "files": len(files),
        "lines": count_lines(files),
        "complexity": distribution([float(f["ccn"]) for f in all_functions]),
        "length": distribution([float(f["length"]) for f in all_functions]),
        "by_file": by_file,
        "hotspots": compute_hotspots(all_functions),
    }
    if lint is not None:
        result["lint"] = lint
    return result


def git_output(*args: str) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True, cwd=REPO_ROOT)
    return result.stdout.strip()


def collect_run_metadata() -> dict[str, str]:
    branch = (
        os.environ.get("GITHUB_REF_NAME")
        or git_output("rev-parse", "--abbrev-ref", "HEAD")
        or "unknown"
    )
    commit = git_output("rev-parse", "--short", "HEAD") or "unknown"
    dirty = bool(git_output("status", "--porcelain"))
    hostname = os.environ.get("RUNNER_NAME") or socket.gethostname()
    return {
        "branch": branch,
        "commit": commit,
        "dirty": str(dirty).lower(),
        "hostname": hostname,
    }


def _flatten(data: dict, prefix: str, out: dict[str, float]) -> None:
    for key, value in data.items():
        full_key = f"{prefix}/{key}" if prefix else key
        if isinstance(value, (int, float)):
            out[full_key] = float(value)
        elif isinstance(value, dict):
            _flatten(value, full_key, out)


def flatten_for_wandb(metrics: dict) -> dict[str, float]:
    flat: dict[str, float] = {}
    for group in ("code", "tests"):
        group_data = metrics.get(group, {})
        for section in ("lines", "complexity", "length", "lint"):
            if section in group_data and isinstance(group_data[section], dict):
                _flatten(group_data[section], f"{group}/{section}", flat)
    return flat


def push_to_wandb(metrics: dict, run_metadata: dict[str, str]) -> None:
    api_key = os.environ.get("PRIVATE_WANDB_API_KEY")
    if not api_key:
        print("Error: $PRIVATE_WANDB_API_KEY is not set.", file=sys.stderr)
        sys.exit(1)

    try:
        import wandb  # type: ignore[import-untyped]
    except ImportError:
        print("Error: wandb not available. Run with: uv run --with lizard --with wandb scripts/metrics.py --use-wandb", file=sys.stderr)
        sys.exit(1)

    wandb.login(key=api_key, relogin=True)
    run = wandb.init(
        project=WANDB_PROJECT,
        entity=WANDB_ENTITY,
        config=run_metadata,
        tags=[run_metadata["branch"]],
    )
    wandb.log(flatten_for_wandb(metrics))
    run.finish()
    print(f"Pushed to wandb: {WANDB_ENTITY}/{WANDB_PROJECT}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Compute Swift code quality metrics.")
    parser.add_argument("--use-wandb", action="store_true", help="Push metrics to wandb after computing.")
    args = parser.parse_args()

    code_files, test_files = classify_files(SWIFT_ROOTS)

    if not code_files and not test_files:
        print("No Swift files found under", ", ".join(str(r) for r in SWIFT_ROOTS), file=sys.stderr)
        sys.exit(1)

    swiftlint_available = shutil.which("swiftlint") is not None
    print(
        f"Analysing {len(code_files)} code files and {len(test_files)} test files"
        f"{' (swiftlint available)' if swiftlint_available else ' (swiftlint not found — skipping lint)'}..."
    )

    metrics: dict = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "code": compute_group_metrics(code_files),
        "tests": compute_group_metrics(test_files),
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(metrics, indent=2))
    print(f"Wrote {OUTPUT_PATH}")

    if args.use_wandb:
        run_metadata = collect_run_metadata()
        push_to_wandb(metrics, run_metadata)


if __name__ == "__main__":
    main()
