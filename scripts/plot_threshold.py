#!/usr/bin/env python3
"""Plot ROC + precision/recall vs. the recall gate's distance threshold.

Reads the per-candidate scores dumped by `engram-eval --dump-scores`
(`eval/scores-<embedder>.json`: rows of {distance, relevant, kind}) and the
marked thresholds (`eval/thresholds-<embedder>.json`), then renders an ROC curve
(with AUC) and a precision/recall-vs-threshold curve, marking the shipped
`proposed` gate and the legacy `current` ceiling. Writes `eval/threshold.png`.

The gate also has a lexical leg; this models the *semantic distance* knob only —
the dominant control and the thing an AUC actually characterizes.

Run: uv run --with matplotlib --with numpy scripts/plot_threshold.py [embedder]
"""
from __future__ import annotations

import glob
import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
EVAL = ROOT / "eval"


def load() -> tuple[np.ndarray, np.ndarray, dict, str]:
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    scores = sorted(EVAL.glob(f"scores-{arg}.json" if arg else "scores-*.json"))
    if not scores:
        sys.exit("no eval/scores-*.json — run: swift run engram-eval --dump-scores")
    path = scores[-1]
    embedder = path.stem.replace("scores-", "")
    rows = json.loads(path.read_text())
    dist = np.array([r["distance"] for r in rows], dtype=float)
    rel = np.array([bool(r["relevant"]) for r in rows], dtype=bool)
    tpath = EVAL / f"thresholds-{embedder}.json"
    marks = json.loads(tpath.read_text()) if tpath.exists() else {"currentMaxDistance": 0.45, "proposedMaxDistance": 0.10}
    return dist, rel, marks, embedder


def curve(dist: np.ndarray, rel: np.ndarray, taus: np.ndarray):
    """A candidate is injected when distance < tau. Sweep tau → TPR/FPR/P/R."""
    P = int(rel.sum())
    N = int((~rel).sum())
    tpr, fpr, prec, rec = [], [], [], []
    for tau in taus:
        pred = dist < tau
        tp = int((pred & rel).sum())
        fp = int((pred & ~rel).sum())
        tpr.append(tp / P if P else 0.0)
        fpr.append(fp / N if N else 0.0)
        # Precision is undefined when nothing is injected — leave it NaN so the
        # plot doesn't draw a misleading "P=1.0" shelf over the inject-nothing band.
        prec.append(tp / (tp + fp) if (tp + fp) else float("nan"))
        rec.append(tp / P if P else 0.0)
    return np.array(tpr), np.array(fpr), np.array(prec), np.array(rec)


def at_threshold(dist, rel, tau):
    pred = dist < tau
    tp = int((pred & rel).sum())
    fp = int((pred & ~rel).sum())
    P = int(rel.sum())
    prec = tp / (tp + fp) if (tp + fp) else 1.0
    rec = tp / P if P else 0.0
    f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
    return prec, rec, f1


def main() -> None:
    dist, rel, marks, embedder = load()
    cur = float(marks["currentMaxDistance"])
    prop = float(marks["proposedMaxDistance"])

    taus = np.linspace(0.0, max(0.5, cur + 0.02), 400)
    tpr, fpr, prec, rec = curve(dist, rel, taus)

    # ROC AUC over the swept range (sort by FPR for a monotone integral).
    trapz = getattr(np, "trapezoid", None) or np.trapz  # numpy 2.x renamed trapz
    order = np.argsort(fpr)
    auc = float(trapz(tpr[order], fpr[order]))

    # Best-F1 threshold (a reasonable "optimal" operating point).
    f1s = np.where((prec + rec) > 0, 2 * prec * rec / (prec + rec + 1e-12), 0.0)
    best = int(np.argmax(f1s))
    best_tau = float(taus[best])

    fig, (ax_roc, ax_pr) = plt.subplots(1, 2, figsize=(13, 5.2))

    # ── ROC ──
    ax_roc.plot(fpr, tpr, color="#2E3A59", lw=2, label=f"ROC (AUC={auc:.3f})")
    ax_roc.plot([0, 1], [0, 1], ls=":", color="#aaa", lw=1)
    for tau, name, color in [(cur, f"current {cur:.2f}", "#C0504D"), (prop, f"proposed {prop:.2f} (shipped)", "#4F8A4F")]:
        p, r, _ = at_threshold(dist, rel, tau)
        # locate the curve point nearest this tau
        i = int(np.argmin(np.abs(taus - tau)))
        ax_roc.scatter([fpr[i]], [tpr[i]], color=color, zorder=5, s=70)
        ax_roc.annotate(f"{name}\nP={p:.2f} R={r:.2f}", (fpr[i], tpr[i]),
                        textcoords="offset points", xytext=(8, -4 if "current" in name else 10),
                        fontsize=9, color=color)
    ax_roc.set_xlabel("false-positive rate (off-topic injected)")
    ax_roc.set_ylabel("true-positive rate (relevant injected)")
    ax_roc.set_title(f"ROC — distance gate ({embedder})")
    ax_roc.legend(loc="lower right")
    ax_roc.grid(alpha=0.2)

    # ── precision / recall vs threshold ──
    ax_pr.plot(taus, prec, color="#2E3A59", lw=2, label="precision")
    ax_pr.plot(taus, rec, color="#E08A4C", lw=2, label="recall")
    for tau, name, color in [(cur, f"current {cur:.2f}", "#C0504D"), (prop, f"proposed {prop:.2f}", "#4F8A4F"), (best_tau, f"best-F1 {best_tau:.2f}", "#3b4a82")]:
        ax_pr.axvline(tau, color=color, ls="--", lw=1.3, label=name)
    ax_pr.set_xlabel("maxDistance threshold τ  (inject when distance < τ)")
    ax_pr.set_ylabel("precision / recall")
    ax_pr.set_title("precision & recall vs. threshold")
    ax_pr.legend(loc="center right", fontsize=8)
    ax_pr.grid(alpha=0.2)

    fig.tight_layout()
    out = EVAL / "threshold.png"
    fig.savefig(out, dpi=140)

    # text summary
    pc, rc, fc = at_threshold(dist, rel, cur)
    pp, rp, fp_ = at_threshold(dist, rel, prop)
    pb, rb, fb = at_threshold(dist, rel, best_tau)
    print(f"embedder: {embedder}   candidates: {len(dist)}  relevant: {int(rel.sum())}  ROC-AUC: {auc:.3f}")
    print(f"  current  τ={cur:.2f} : precision {pc:.3f}  recall {rc:.3f}  F1 {fc:.3f}")
    print(f"  proposed τ={prop:.2f} : precision {pp:.3f}  recall {rp:.3f}  F1 {fp_:.3f}   ← shipped")
    print(f"  best-F1  τ={best_tau:.2f} : precision {pb:.3f}  recall {rb:.3f}  F1 {fb:.3f}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
