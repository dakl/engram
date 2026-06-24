#!/usr/bin/env python3
"""Compare embedding models on Engram's labeled eval corpus.

Reads the *same* fixtures the Swift `engram-eval` uses
(`Sources/engram-eval/Resources/{corpus,queries}.json`), embeds the corpus +
prompts with several local sentence-transformer models, and scores each model's
*semantic separability* — how well cosine distance tells a query's relevant
memories from the rest. Output: an overlaid ROC plot (`eval/embeddings-roc.png`)
+ a table (ROC-AUC, Recall@3, MRR) sorted by AUC.

This is an EXPLORATION harness, separate from the Swift regression gate. It tells
you *relative* model ranking + headroom — the absolute numbers differ from
production (which uses Apple's NLContextualEmbedding + a lexical leg + RRF). The
sibling-near-duplicate labeling caps AUC for every model equally, so trust the
ranking, not the absolute height. The shipped embedder's number (~0.71 on this
corpus, from `engram-eval --dump-scores`) is cited for reference but isn't a
like-for-like candidate pool.

Run:
  uv run --with sentence-transformers --with torch --with scikit-learn \
         --with matplotlib --with numpy scripts/embeddings_eval.py [--quick]
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "Sources/engram-eval/Resources"
EVAL = ROOT / "eval"

# (label, hf_id, query_prefix, doc_prefix) — prefixes per each model's card.
MODELS = [
    ("MiniLM-L6 (384d)", "sentence-transformers/all-MiniLM-L6-v2", "", ""),
    ("mpnet-base (768d)", "sentence-transformers/all-mpnet-base-v2", "", ""),
    ("bge-small-en-1.5", "BAAI/bge-small-en-v1.5",
     "Represent this sentence for searching relevant passages: ", ""),
    ("e5-small-v2", "intfloat/e5-small-v2", "query: ", "passage: "),
    ("gte-small", "thenlper/gte-small", "", ""),
    ("arctic-embed-s", "Snowflake/snowflake-arctic-embed-s",
     "Represent this sentence for searching relevant passages: ", ""),
]
QUICK = [MODELS[0], MODELS[2], MODELS[3]]  # --quick: MiniLM, bge, e5


def load_fixtures():
    corpus = json.loads((RES / "corpus.json").read_text())["memories"]
    queries = json.loads((RES / "queries.json").read_text())["queries"]
    slugs = [m["slug"] for m in corpus]
    docs = [m["content"] for m in corpus]
    slug_idx = {s: i for i, s in enumerate(slugs)}
    return docs, slug_idx, queries


def score_model(label, hf_id, qp, dp, docs, slug_idx, queries):
    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(hf_id)
    doc_emb = model.encode([dp + d for d in docs], normalize_embeddings=True,
                           convert_to_numpy=True, show_progress_bar=False)
    q_emb = model.encode([qp + q["prompt"] for q in queries], normalize_embeddings=True,
                         convert_to_numpy=True, show_progress_bar=False)
    # cosine distance = 1 - cos sim (vectors are normalized → dot = cos)
    dist = 1.0 - q_emb @ doc_emb.T  # (Q, D)

    # ROC is scored over each query's POOL nearest candidates — the *hard*
    # negatives (a query's nearest distractors), mirroring the production fetch
    # limit. Pooling all 153 memories would drown the ROC in easy true-negatives
    # and inflate AUC; this keeps it comparable to the shipped top-8 number.
    pool = 8
    labels, scores = [], []          # score = -distance (higher = closer)
    recalls, rrs = [], []
    for qi, q in enumerate(queries):
        rel = {slug_idx[s] for s in q["relevant"] if s in slug_idx}
        row = dist[qi]
        order = np.argsort(row)  # nearest first
        for di in order[:pool].tolist():
            labels.append(1 if di in rel else 0)
            scores.append(-row[di])
        if rel:  # ranking metrics only over labeled queries
            top3 = set(order[:3].tolist())
            recalls.append(len(top3 & rel) / len(rel))
            rank = next((r for r, di in enumerate(order.tolist(), 1) if di in rel), None)
            rrs.append(1.0 / rank if rank else 0.0)
    return np.array(labels), np.array(scores), float(np.mean(recalls)), float(np.mean(rrs))


def main():
    from sklearn.metrics import roc_auc_score, roc_curve
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    quick = "--quick" in sys.argv
    models = QUICK if quick else MODELS
    docs, slug_idx, queries = load_fixtures()
    n_rel = sum(1 for q in queries if q["relevant"])
    print(f"corpus: {len(docs)} memories · queries: {len(queries)} ({n_rel} labeled)\n")

    fig, ax = plt.subplots(figsize=(7.5, 7))
    ax.plot([0, 1], [0, 1], ls=":", color="#bbb", lw=1)
    rows = []
    for label, hf_id, qp, dp in models:
        t0 = time.time()
        try:
            y, s, recall3, mrr = score_model(label, hf_id, qp, dp, docs, slug_idx, queries)
        except Exception as exc:  # noqa: BLE001 — one bad model shouldn't sink the run
            print(f"  ✗ {label}: {exc}")
            continue
        auc = roc_auc_score(y, s)
        fpr, tpr, _ = roc_curve(y, s)
        ax.plot(fpr, tpr, lw=2, label=f"{label}  AUC={auc:.3f}")
        rows.append((label, auc, recall3, mrr, time.time() - t0))
        print(f"  ✓ {label:22} AUC={auc:.3f}  Recall@3={recall3:.3f}  MRR={mrr:.3f}  ({time.time()-t0:.0f}s)")

    ax.set_xlabel("false-positive rate")
    ax.set_ylabel("true-positive rate")
    ax.set_title("Embedding models — semantic separability on Engram's eval corpus")
    ax.legend(loc="lower right", fontsize=9)
    ax.grid(alpha=0.2)
    EVAL.mkdir(exist_ok=True)
    out = EVAL / "embeddings-roc.png"
    fig.tight_layout(); fig.savefig(out, dpi=140)

    rows.sort(key=lambda r: -r[1])
    print(f"\n{'model':24} {'ROC-AUC':>8} {'Recall@3':>9} {'MRR':>6}")
    for label, auc, r3, mrr, _ in rows:
        print(f"{label:24} {auc:>8.3f} {r3:>9.3f} {mrr:>6.3f}")
    print(f"\nshipped (NLContextualEmbedding, ~top-8 hybrid pool): ROC-AUC ≈ 0.71  (reference, not like-for-like)")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
