"""
Step 1 — Build the Azure AI Search layer.

Creates ONE index per domain (a mix of doc types lives in each), then chunks, embeds, and
uploads the Fabrikam manufacturing corpus. Each index has:
  * a vector field (chunk_vector) with an Azure OpenAI **integrated vectorizer**, so both
    Foundry IQ and the MAF path can send plain text and let the service embed at query time;
  * a **semantic configuration** ("semantic-config") used for L2 reranking.

Run:
    python build_indexes.py            # create/update all indexes and upload docs
    python build_indexes.py --recreate # delete and rebuild the indexes first

Auth: AZURE_SEARCH_API_KEY + AZURE_OPENAI_API_KEY if set, otherwise DefaultAzureCredential.
"""

import sys

from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    AzureOpenAIVectorizer,
    AzureOpenAIVectorizerParameters,
    HnswAlgorithmConfiguration,
    SearchableField,
    SearchField,
    SearchFieldDataType,
    SearchIndex,
    SemanticConfiguration,
    SemanticField,
    SemanticPrioritizedFields,
    SemanticSearch,
    SimpleField,
    VectorSearch,
    VectorSearchProfile,
)

import common as cm
import config as cfg

SEMANTIC_CONFIG = "semantic-config"


def build_index(domain: str) -> SearchIndex:
    name = cfg.index_name(domain)
    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True),
        SimpleField(name="doc_id", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SearchableField(name="title", type=SearchFieldDataType.String, filterable=True),
        SimpleField(name="domain", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SimpleField(name="product", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SimpleField(name="source", type=SearchFieldDataType.String, filterable=True),
        SearchableField(name="chunk", type=SearchFieldDataType.String),
        SimpleField(name="page_number", type=SearchFieldDataType.Int32, filterable=True, sortable=True),
        SearchField(
            name="chunk_vector",
            type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
            searchable=True,
            stored=False,
            vector_search_dimensions=cfg.EMBED_DIMENSIONS,
            vector_search_profile_name="hnsw-profile",
        ),
    ]
    vector_search = VectorSearch(
        algorithms=[HnswAlgorithmConfiguration(name="hnsw")],
        profiles=[
            VectorSearchProfile(
                name="hnsw-profile",
                algorithm_configuration_name="hnsw",
                vectorizer_name="aoai-vectorizer",
            )
        ],
        vectorizers=[
            AzureOpenAIVectorizer(
                vectorizer_name="aoai-vectorizer",
                parameters=AzureOpenAIVectorizerParameters(
                    resource_url=cfg.AOAI_ENDPOINT,
                    deployment_name=cfg.EMBED_DEPLOYMENT,
                    model_name=cfg.EMBED_MODEL,
                ),
            )
        ],
    )
    semantic_search = SemanticSearch(
        default_configuration_name=SEMANTIC_CONFIG,
        configurations=[
            SemanticConfiguration(
                name=SEMANTIC_CONFIG,
                prioritized_fields=SemanticPrioritizedFields(
                    title_field=SemanticField(field_name="title"),
                    content_fields=[SemanticField(field_name="chunk")],
                ),
            )
        ],
    )
    return SearchIndex(
        name=name,
        fields=fields,
        vector_search=vector_search,
        semantic_search=semantic_search,
    )


def main() -> None:
    recreate = "--recreate" in sys.argv
    endpoint = cfg.require_search()
    cred = cm.search_credential()
    index_client = SearchIndexClient(endpoint=endpoint, credential=cred)

    cm.header(
        "RAG demo — Step 1: build Azure AI Search indexes",
        [
            f"Search service : {endpoint}",
            f"Embeddings     : {cfg.EMBED_DEPLOYMENT} ({cfg.EMBED_DIMENSIONS} dims, AOAI-direct)",
            f"Indexes        : {', '.join(cfg.index_name(d) for d in cfg.DOMAINS)}",
        ],
    )

    for domain in cfg.DOMAINS:
        name = cfg.index_name(domain)
        cm.section(f"Index '{name}'  (domain: {domain})")

        if recreate:
            try:
                index_client.delete_index(name)
                print(cm.c("  deleted existing index", cm.GREY))
            except Exception:  # noqa: BLE001 - fine if it didn't exist
                pass

        index_client.create_or_update_index(build_index(domain))
        print(cm.c("  index schema created/updated", cm.GREEN))

        records = cm.load_domain_chunks(domain)
        print(cm.c(f"  loaded {len(records)} chunks from corpus; embedding…", cm.DIM))
        vectors = cm.embed_texts([r["chunk"] for r in records])
        for r, v in zip(records, vectors):
            r["chunk_vector"] = v

        search_client = SearchClient(endpoint=endpoint, index_name=name, credential=cred)
        result = search_client.upload_documents(documents=records)
        ok = sum(1 for r in result if r.succeeded)
        print(cm.c(f"  uploaded {ok}/{len(records)} chunks", cm.GREEN if ok == len(records) else cm.YELLOW))

    print()
    print(cm.c(" Done. Next: python foundry_iq.py --setup   (build the knowledge base)", cm.BOLD))


if __name__ == "__main__":
    main()
