"""
Step 2 — Foundry IQ side: managed agentic retrieval (Azure AI Search knowledge base).

This is the MANAGED engine. One knowledge source per index, a single knowledge base across
all three, and a planner LLM that decomposes the query, fans out subqueries, reranks, and
(optionally) synthesizes a cited answer — all inside the service.

IMPORTANT (governance): the knowledge-base model (`KnowledgeBaseAzureOpenAIModel`) points
straight at Azure OpenAI. Foundry IQ does NOT support an APIM / AI-gateway hop for this
planner/synthesis model today — that is the documented gap versus the MAF path, which is
fully APIM-routable.

Usage:
    python foundry_iq.py --setup           # create knowledge sources + knowledge base
    python foundry_iq.py "your question"   # run one agentic retrieval

`run_query(question)` is imported by compare.py. It degrades gracefully: if the preview
knowledge-base SDK/API isn't available on your service, it returns a structured "unavailable"
result instead of raising, so the comparison still runs.
"""

import sys
import time

import common as cm
import config as cfg

# The knowledge base + agentic-retrieval types live in preview namespaces. Import lazily so
# the module loads even on SDKs that predate them.
try:
    from azure.search.documents.indexes import SearchIndexClient
    from azure.search.documents.indexes.models import (
        KnowledgeBase,
        KnowledgeBaseAzureOpenAIModel,
        KnowledgeSourceReference,
        SearchIndexFieldReference,
        SearchIndexKnowledgeSource,
        SearchIndexKnowledgeSourceParameters,
    )
    from azure.search.documents.knowledgebases import KnowledgeBaseRetrievalClient
    from azure.search.documents.knowledgebases.models import (
        KnowledgeBaseMessage,
        KnowledgeBaseMessageTextContent,
        KnowledgeBaseRetrievalRequest,
        SearchIndexKnowledgeSourceParams,
    )
    from azure.search.documents.indexes.models import AzureOpenAIVectorizerParameters

    _KB_AVAILABLE = True
    _IMPORT_ERROR = ""
except Exception as exc:  # noqa: BLE001 - record and degrade
    _KB_AVAILABLE = False
    _IMPORT_ERROR = f"{type(exc).__name__}: {exc}"

SEMANTIC_CONFIG = "semantic-config"


def setup() -> None:
    """Create one knowledge source per index, then a single knowledge base across all three."""
    if not _KB_AVAILABLE:
        raise SystemExit(
            "Foundry IQ knowledge-base SDK not available: "
            f"{_IMPORT_ERROR}\nInstall a preview azure-search-documents (see requirements.txt)."
        )
    endpoint = cfg.require_search()
    cred = cm.search_credential()
    index_client = SearchIndexClient(endpoint=endpoint, credential=cred)

    cm.header(
        "RAG demo — Step 2: build the Foundry IQ knowledge base",
        [
            f"Knowledge base : {cfg.KNOWLEDGE_BASE_NAME}",
            f"Planner model  : {cfg.KB_CHAT_DEPLOYMENT} (Azure OpenAI DIRECT — APIM not supported here)",
            f"Sources        : {', '.join(cfg.knowledge_source_name(d) for d in cfg.DOMAINS)}",
        ],
    )

    for domain in cfg.DOMAINS:
        ks_name = cfg.knowledge_source_name(domain)
        ks = SearchIndexKnowledgeSource(
            name=ks_name,
            description=f"Fabrikam {domain} documents.",
            search_index_parameters=SearchIndexKnowledgeSourceParameters(
                search_index_name=cfg.index_name(domain),
                semantic_configuration_name=SEMANTIC_CONFIG,
                source_data_fields=[
                    SearchIndexFieldReference(name="id"),
                    SearchIndexFieldReference(name="title"),
                    SearchIndexFieldReference(name="chunk"),
                    SearchIndexFieldReference(name="doc_id"),
                ],
            ),
        )
        index_client.create_or_update_knowledge_source(knowledge_source=ks)
        print(cm.c(f"  knowledge source '{ks_name}' ready", cm.GREEN))

    kb = KnowledgeBase(
        name=cfg.KNOWLEDGE_BASE_NAME,
        models=[
            KnowledgeBaseAzureOpenAIModel(
                azure_open_ai_parameters=AzureOpenAIVectorizerParameters(
                    resource_url=cfg.AOAI_ENDPOINT,
                    deployment_name=cfg.KB_CHAT_DEPLOYMENT,
                    model_name=cfg.KB_CHAT_MODEL,
                )
            )
        ],
        knowledge_sources=[
            KnowledgeSourceReference(name=cfg.knowledge_source_name(d)) for d in cfg.DOMAINS
        ],
        output_mode="answerSynthesis",
        answer_instructions=(
            "Answer the manufacturing question using only the knowledge sources. Be concise "
            "and cite the document titles you used."
        ),
    )
    index_client.create_or_update_knowledge_base(kb)
    print(cm.c(f"  knowledge base '{cfg.KNOWLEDGE_BASE_NAME}' ready", cm.GREEN))
    print()
    print(cm.c(" Done. Next: python maf_rag.py \"a question\"  or  python compare.py", cm.BOLD))


def run_query(question: str) -> dict:
    """Run one agentic retrieval. Returns a normalized result dict (see compare.py)."""
    if not _KB_AVAILABLE:
        return {
            "engine": "foundry-iq",
            "available": False,
            "answer": "",
            "doc_ids": [],
            "subqueries": [],
            "context": "",
            "elapsed_s": 0.0,
            "error": f"knowledge-base SDK unavailable: {_IMPORT_ERROR}",
        }

    endpoint = cfg.require_search()
    cred = cm.search_credential()
    client = KnowledgeBaseRetrievalClient(
        endpoint=endpoint,
        knowledge_base_name=cfg.KNOWLEDGE_BASE_NAME,
        credential=cred,
    )
    request = KnowledgeBaseRetrievalRequest(
        messages=[
            KnowledgeBaseMessage(
                role="user",
                content=[KnowledgeBaseMessageTextContent(text=question)],
            )
        ],
        knowledge_source_params=[
            SearchIndexKnowledgeSourceParams(
                knowledge_source_name=cfg.knowledge_source_name(d),
                include_references=True,
                include_reference_source_data=True,
            )
            for d in cfg.DOMAINS
        ],
        include_activity=True,
    )

    start = time.perf_counter()
    try:
        result = client.retrieve(retrieval_request=request)
    except Exception as exc:  # noqa: BLE001 - report honestly
        return {
            "engine": "foundry-iq",
            "available": False,
            "answer": "",
            "doc_ids": [],
            "subqueries": [],
            "context": "",
            "elapsed_s": time.perf_counter() - start,
            "error": f"{type(exc).__name__}: {exc}",
        }
    elapsed = time.perf_counter() - start

    answer = _extract_answer(result)
    doc_ids = _extract_doc_ids(result)
    subqueries = _extract_subqueries(result)
    context = _extract_context(result)
    return {
        "engine": "foundry-iq",
        "available": True,
        "answer": answer,
        "doc_ids": sorted(set(doc_ids)),
        "subqueries": subqueries,
        "context": context,
        "elapsed_s": elapsed,
        "error": "",
    }


# --- Response parsing (defensive across preview shapes) ------------------------
def _extract_answer(result) -> str:
    response = getattr(result, "response", None)
    if response:
        parts = []
        for msg in response:
            for content in getattr(msg, "content", []) or []:
                text = getattr(content, "text", None)
                if text:
                    parts.append(text)
        if parts:
            return "\n".join(parts).strip()
    return str(getattr(result, "response", "") or "").strip()


def _extract_doc_ids(result) -> list[str]:
    ids: list[str] = []
    for ref in getattr(result, "references", []) or []:
        data = getattr(ref, "source_data", None) or {}
        if isinstance(data, dict):
            ids.append(data.get("doc_id") or data.get("id") or "")
        doc_key = getattr(ref, "doc_key", None) or getattr(ref, "document_key", None)
        if doc_key:
            ids.append(str(doc_key).rsplit("-", 1)[0])
    return [i for i in ids if i]


def _extract_subqueries(result) -> list[str]:
    subs: list[str] = []
    for act in getattr(result, "activity", []) or []:
        q = getattr(act, "query", None) or getattr(act, "search", None)
        if isinstance(q, str):
            subs.append(q)
        elif q is not None:
            text = getattr(q, "search", None) or getattr(q, "text", None)
            if text:
                subs.append(text)
    return subs


def _extract_context(result) -> str:
    parts: list[str] = []
    for ref in getattr(result, "references", []) or []:
        data = getattr(ref, "source_data", None) or {}
        if isinstance(data, dict):
            chunk = data.get("chunk") or data.get("content") or ""
            title = data.get("title") or data.get("doc_id") or ""
            if chunk:
                parts.append(f"[{title}]\n{chunk}" if title else chunk)
    if parts:
        return "\n\n---\n\n".join(parts[:8])
    # Fall back to the synthesized response text if references carried no source data.
    return _extract_answer(result)


def main() -> None:
    if "--setup" in sys.argv:
        setup()
        return
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    question = args[0] if args else "What pressure is the HPX-450 rated for and what fluid should it use?"
    cm.header("Foundry IQ — single agentic retrieval", [f"Q: {question}"])
    res = run_query(question)
    if not res["available"]:
        print(cm.c(f"  unavailable: {res['error']}", cm.RED))
        return
    if res["subqueries"]:
        print(cm.c("  planner subqueries:", cm.YELLOW))
        for s in res["subqueries"]:
            print(cm.c(f"    • {s}", cm.DIM))
    print(cm.c(f"  docs used: {', '.join(res['doc_ids']) or '(none reported)'}", cm.CYAN))
    print(cm.c(f"  {res['elapsed_s']:.2f}s", cm.GREY))
    print()
    print(res["answer"])


if __name__ == "__main__":
    main()
