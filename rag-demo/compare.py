"""
Step 4 — Compare MAF agents vs Foundry IQ with ACTUAL evaluations.

For every question in questions.py it runs BOTH engines, then scores each answer with the
Azure AI Evaluation SDK (groundedness, relevance, retrieval) plus a deterministic ground-truth
document-recall metric. Results are printed per question and as a summary table, and written
to results.json / results.csv for the record.

Run:
    python compare.py                 # all questions, both engines, full evals
    python compare.py --no-evals      # skip the LLM judge (deterministic metrics only)
    python compare.py --only maf      # or --only foundry-iq
    python compare.py --q q3-cross-pump-fluid
"""

import csv
import json
import math
import os
import sys

import common as cm
import config as cfg
import foundry_iq
import maf_rag
from evals import Evaluators
from questions import QUESTIONS

RESULTS_JSON = os.path.join(os.path.dirname(__file__), "results.json")
RESULTS_CSV = os.path.join(os.path.dirname(__file__), "results.csv")
ENGINES = [
    ("maf", "MAF agent (APIM-governed)", cm.BLUE),
    ("foundry-iq", "Foundry IQ (managed)", cm.MAGENTA),
]


def _recall(expected: list[str], got: list[str]) -> float:
    if not expected:
        return 1.0
    return sum(1 for d in expected if d in got) / len(expected)


def _fmt(x, pct: bool = False) -> str:
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "  —  "
    return f"{x:.0%}" if pct else f"{x:.2f}"


def _none(x):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return None
    return round(float(x), 2)


def _print_engine_row(label: str, color: str, res: dict, ev: dict, expected: list[str]) -> None:
    print(cm.c(f"  ── {label} ", cm.BOLD, color) + cm.c("─" * max(0, 66 - len(label)), color))
    if not res["available"]:
        print(cm.c(f"     unavailable: {res['error']}", cm.RED))
        return
    rec = _recall(expected, res["doc_ids"])
    rec_color = cm.GREEN if rec == 1.0 else (cm.YELLOW if rec >= 0.5 else cm.RED)
    n_subq = len(res["subqueries"])
    latency = f"{res['elapsed_s']:.2f}s"
    print(
        f"     recall {cm.c(_fmt(rec, True), cm.BOLD, rec_color)}"
        f"   ground {cm.c(_fmt(ev['groundedness']), cm.CYAN)}"
        f"   relev {cm.c(_fmt(ev['relevance']), cm.CYAN)}"
        f"   retr {cm.c(_fmt(ev['retrieval']), cm.CYAN)}"
        f"   {cm.c(f'{n_subq} sub-q', cm.GREY)}"
        f"   {cm.c(latency, cm.GREY)}"
    )
    print(cm.c(f"     docs: {', '.join(res['doc_ids']) or '(none)'}", cm.DIM))
    answer = (res["answer"] or "").replace("\n", "\n     ")
    print(cm.c("     answer: ", cm.DIM) + answer)


def main() -> None:
    do_evals = "--no-evals" not in sys.argv
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    pick = sys.argv[sys.argv.index("--q") + 1] if "--q" in sys.argv else None
    questions = [q for q in QUESTIONS if not pick or q["id"] == pick]

    evaluators = Evaluators() if do_evals else None
    judge_state = (
        "ready" if (evaluators and evaluators.available)
        else ("disabled" if not do_evals else f"unavailable ({evaluators.error if evaluators else ''})")
    )

    cm.header(
        "RAG comparison — MAF agents vs Foundry IQ (with evals)",
        [
            f"Indexes      : {', '.join(cfg.index_name(d) for d in cfg.DOMAINS)}",
            f"MAF model    : {cfg.MAF_MODEL} via APIM ({cfg.APIM_GATEWAY_URL or 'NOT SET'})",
            f"Foundry IQ KB: {cfg.KNOWLEDGE_BASE_NAME} (planner {cfg.KB_CHAT_DEPLOYMENT}, AOAI-direct)",
            f"Judge        : {cfg.KB_CHAT_DEPLOYMENT} — {judge_state}",
            f"Questions    : {len(questions)}",
        ],
    )

    rows: list[dict] = []
    for q in questions:
        cm.section(f"{q['id']} — {q['text']}")
        print(cm.c(f"  expected docs: {', '.join(q['expects'])}   ({q['note']})", cm.DIM))
        print()
        for engine, label, color in ENGINES:
            if only and only != engine:
                continue
            res = maf_rag.run_query_sync(q["text"]) if engine == "maf" else foundry_iq.run_query(q["text"])
            ev = {"groundedness": float("nan"), "relevance": float("nan"), "retrieval": float("nan")}
            if res["available"] and evaluators and evaluators.available:
                ev = evaluators.evaluate(q["text"], res["answer"], res.get("context", ""))
            _print_engine_row(label, color, res, ev, q["expects"])
            rows.append({
                "question_id": q["id"],
                "engine": engine,
                "available": res["available"],
                "doc_recall": _recall(q["expects"], res["doc_ids"]) if res["available"] else None,
                "groundedness": _none(ev["groundedness"]),
                "relevance": _none(ev["relevance"]),
                "retrieval": _none(ev["retrieval"]),
                "subqueries": len(res["subqueries"]) if res["available"] else None,
                "latency_s": round(res["elapsed_s"], 2) if res["available"] else None,
                "doc_ids": res["doc_ids"],
                "answer": res["answer"],
                "error": res["error"],
            })
            print()

    _write(rows)
    _summary(rows)


def _write(rows: list[dict]) -> None:
    with open(RESULTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=2)
    fields = ["question_id", "engine", "available", "doc_recall", "groundedness",
              "relevance", "retrieval", "subqueries", "latency_s"]
    with open(RESULTS_CSV, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for r in rows:
            writer.writerow(r)
    print(cm.c(f"  results written: {os.path.basename(RESULTS_JSON)}, {os.path.basename(RESULTS_CSV)}", cm.DIM))


def _avg(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def _summary(rows: list[dict]) -> None:
    print()
    cm.header("Summary — mean metrics per engine")
    head = (
        f"  {'engine':<26}{'doc_recall':>12}{'ground':>9}{'relev':>9}"
        f"{'retr':>9}{'sub-q':>8}{'latency':>10}"
    )
    print(cm.c(head, cm.BOLD))
    print(cm.c("  " + "─" * (len(head) - 2), cm.GREY))
    for engine, label, _ in ENGINES:
        er = [r for r in rows if r["engine"] == engine and r["available"]]
        if not er:
            print(cm.c(f"  {label:<26}   — not run / unavailable —", cm.DIM))
            continue
        subq = _avg([r["subqueries"] for r in er]) or 0.0
        lat = _avg([r["latency_s"] for r in er]) or 0.0
        print(
            f"  {label:<26}"
            f"{_fmt(_avg([r['doc_recall'] for r in er]), True):>12}"
            f"{_fmt(_avg([r['groundedness'] for r in er])):>9}"
            f"{_fmt(_avg([r['relevance'] for r in er])):>9}"
            f"{_fmt(_avg([r['retrieval'] for r in er])):>9}"
            f"{subq:>8.1f}"
            f"{lat:>9.2f}s"
        )
    print()
    print(cm.c(" doc_recall: deterministic vs ground-truth docs. ground/relev/retr: 1–5 LLM judge.", cm.DIM))
    print(cm.c(" MAF tokens are APIM-governed; Foundry IQ's planner calls Azure OpenAI directly.", cm.DIM))


if __name__ == "__main__":
    main()
