"""
Step 3 — MAF side: a client-orchestrated agent that replicates Foundry IQ.

Instead of the managed knowledge base, a Microsoft Agent Framework (MAF) agent owns the
retrieval loop. It is given ONE tool — `search_manufacturing_docs` — and instructed to:
  1. decompose the question into focused sub-queries,
  2. call the tool once per sub-query (the "orchestrator that fires multiple requests"),
  3. read the reranked hits and search again if coverage is thin (iterative retrieval),
  4. answer concisely with citations.

The tool runs **hybrid (vector + keyword) search with the semantic reranker** across all
three indexes — i.e. the same reranking Foundry IQ uses, but here we own the loop.

Governance: the agent's chat model is the **APIM inference gateway** reused from Scenario 2,
so every planner/synthesis token is APIM-governed — the thing Foundry IQ's planner can't do.

`run_query_sync(question)` is imported by compare.py.
"""

import asyncio
import os
import sys
import time

from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizableTextQuery

import common as cm
import config as cfg

SEMANTIC_CONFIG = "semantic-config"
TOP_PER_INDEX = int(os.environ.get("MAF_TOP_PER_INDEX", "3"))


def _make_chat_client():
    """MAF chat client whose backend is the APIM inference gateway (Scenario 2)."""
    from agent_framework.openai import OpenAIChatCompletionClient

    if not cfg.APIM_GATEWAY_URL or not cfg.APIM_API_KEY:
        raise RuntimeError(
            "Set APIM_GATEWAY_URL and APIM_API_KEY to drive the MAF agent through the "
            "APIM inference gateway (reused from Scenario 2)."
        )
    return OpenAIChatCompletionClient(
        model=cfg.MAF_MODEL,
        azure_endpoint=f"{cfg.APIM_GATEWAY_URL.rstrip('/')}/{cfg.APIM_INFERENCE_PATH}",
        api_key=cfg.APIM_API_KEY,
        api_version=cfg.MAF_API_VERSION,
    )


async def run_query(question: str) -> dict:
    """Run the MAF retrieval agent for one question. Returns a normalized result dict."""
    trace: dict = {"subqueries": [], "doc_ids": set(), "contexts": []}

    endpoint = cfg.require_search()
    cred = cm.search_credential()
    clients = {
        domain: SearchClient(endpoint=endpoint, index_name=cfg.index_name(domain), credential=cred)
        for domain in cfg.DOMAINS
    }

    def search_manufacturing_docs(query: str, domain: str = "") -> str:
        """Search Fabrikam manufacturing docs (hybrid + semantic reranker).

        Args:
            query: a focused natural-language sub-question.
            domain: optionally restrict to 'product-specs', 'maintenance-sops', or
                'safety-compliance'. Leave empty to search all indexes.
        """
        trace["subqueries"].append(query if not domain else f"{query}  [{domain}]")
        targets = [domain] if domain in cfg.DOMAINS else cfg.DOMAINS
        hits: list[tuple[float, str]] = []
        for dom in targets:
            results = clients[dom].search(
                search_text=query,
                vector_queries=[
                    VectorizableTextQuery(
                        text=query, k_nearest_neighbors=TOP_PER_INDEX * 2, fields="chunk_vector"
                    )
                ],
                query_type="semantic",
                semantic_configuration_name=SEMANTIC_CONFIG,
                select=["doc_id", "title", "chunk"],
                top=TOP_PER_INDEX,
            )
            for r in results:
                score = r.get("@search.reranker_score") or r.get("@search.score") or 0.0
                trace["doc_ids"].add(r["doc_id"])
                trace["contexts"].append((score, f"[{r['doc_id']}] {r['title']}\n{r['chunk']}"))
                hits.append((score, f"[{r['doc_id']}] {r['title']}\n{r['chunk']}"))
        hits.sort(key=lambda h: h[0], reverse=True)
        if not hits:
            return "No matching documents."
        return "\n\n---\n\n".join(snippet for _, snippet in hits[: TOP_PER_INDEX * 2])

    client = _make_chat_client()
    agent = client.as_agent(
        name="maf-rag-orchestrator",
        instructions=(
            "You answer questions about Fabrikam manufacturing equipment using ONLY the "
            "search_manufacturing_docs tool. First break the question into focused "
            "sub-questions and search for each one separately. If the returned snippets "
            "don't fully cover the question, search again with refined queries. Then write a "
            "concise answer and cite the document ids (e.g. [spec-hpx450]) you used. If the "
            "documents don't contain the answer, say so."
        ),
        tools=search_manufacturing_docs,
    )

    start = time.perf_counter()
    try:
        result = await agent.run(question)
        answer = (result.text or "").strip()
        error = ""
    except Exception as exc:  # noqa: BLE001 - report honestly
        answer, error = "", f"{type(exc).__name__}: {exc}"
    elapsed = time.perf_counter() - start

    top_ctx = sorted(trace["contexts"], key=lambda x: x[0], reverse=True)
    seen: set[str] = set()
    context_parts: list[str] = []
    for _, snippet in top_ctx:
        if snippet not in seen:
            seen.add(snippet)
            context_parts.append(snippet)
    return {
        "engine": "maf",
        "available": not error,
        "answer": answer,
        "doc_ids": sorted(trace["doc_ids"]),
        "subqueries": trace["subqueries"],
        "context": "\n\n---\n\n".join(context_parts[:8]),
        "elapsed_s": elapsed,
        "error": error,
    }


def run_query_sync(question: str) -> dict:
    return asyncio.run(run_query(question))


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    question = args[0] if args else "What pressure is the HPX-450 rated for and what fluid should it use?"
    cm.header("MAF RAG orchestrator — single run", [f"Q: {question}"])
    res = run_query_sync(question)
    if not res["available"]:
        print(cm.c(f"  failed: {res['error']}", cm.RED))
        return
    print(cm.c("  sub-queries the agent fired:", cm.YELLOW))
    for s in res["subqueries"]:
        print(cm.c(f"    • {s}", cm.DIM))
    print(cm.c(f"  docs used: {', '.join(res['doc_ids']) or '(none)'}", cm.CYAN))
    print(cm.c(f"  {res['elapsed_s']:.2f}s", cm.GREY))
    print()
    print(res["answer"])


if __name__ == "__main__":
    main()
