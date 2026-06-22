# RAG comparison demo — MAF agents vs Foundry IQ

A **segregated** demo (we will wire it to APIM later) that puts the same manufacturing
document corpus behind **Azure AI Search** and answers questions two ways, then compares them:

| | **MAF agent** (`maf_rag.py`) | **Foundry IQ** (`foundry_iq.py`) |
| --- | --- | --- |
| Orchestration | You own it — a Microsoft Agent Framework agent decomposes the query and fires multiple searches | Managed — the knowledge base planner does decomposition + fan-out internally |
| Reranking | Azure AI Search **semantic reranker** (you call it) | Azure AI Search semantic reranker (built in) |
| Iterative retrieval | Agent re-queries when coverage is thin | Managed planner loop |
| Answer synthesis | The agent's chat model | `output_mode="answerSynthesis"` |
| **Model governance** | Chat model runs through the **APIM inference gateway** (reused from Scenario 2) — every token is APIM-governed | Planner/synthesis model calls **Azure OpenAI directly** — APIM hop is **not supported** here |

The corpus is a fictional manufacturer, **Fabrikam Precision Manufacturing** (CNC mills,
hydraulic pumps, robot arms), with nine cross-referenced documents split across three
domains → three indexes:

```
data/docs/product-specs/      -> index  fab-product-specs
data/docs/maintenance-sops/   -> index  fab-maintenance-sops
data/docs/safety-compliance/  -> index  fab-safety-compliance
```

Several evaluation questions are deliberately **cross-domain** (e.g. "convert the HPX-450 to
water-glycol" needs the spec **and** the maintenance SOP **and** the safety datasheet) — those
are where an agentic multi-query planner should beat a single top-k search.

### Multimodal: docs with embedded images

Real manufacturing docs are not plain prose — they carry **performance curves, zone diagrams
and control-loop trends**. Three docs embed a real figure (`make_figures.py` renders them
with matplotlib), and each figure encodes at least one fact that appears **nowhere in the
text**:

| Figure | Doc | Image-only fact |
| --- | --- | --- |
| HPX-450 PQ / efficiency curve | `spec-hpx450` | peak volumetric efficiency **88 % @ 24 L/min** |
| RBX-7 collaborative zones (plan view) | `sds-rob-03` | protective **r=0.90 m → STO**, warning **r=1.60 m → SLS 250 mm/s** |
| MNT-COOL-12 chiller stabilization trend | `mnt-cool-12` | overshoot/settle behaviour + soft-alarm band |

At ingest, each embedded image is **verbalized** by a GPT-4o-mini vision call
(`common.verbalize_image`, cached to a `*.caption.txt` sidecar) and indexed as its own
searchable chunk. Both engines query the same indexes, so they compete on the same
multimodal corpus. Questions `q6` (pump efficiency) and `q7` (robot zones) are answerable
**only** from the figures — a direct test of whether each approach can read the picture.

## Layout

| File | What it does |
| --- | --- |
| `config.py` | Env-first config; reuses `infra/scenario-outputs.json` (Scenario 2 endpoint + APIM gateway). |
| `common.py` | Colors, client factories, corpus loading + chunking, **image verbalization**. |
| `questions.py` | The evaluation question set (with expected source docs), incl. figure-only `q6`/`q7`. |
| `make_figures.py` | **Step 0b** — render the embedded figures (matplotlib) into each domain's `figures/`. |
| `build_indexes.py` | **Step 1** — create the three indexes (vector + semantic + integrated vectorizer), verbalize figures, and upload the corpus. |
| `foundry_iq.py` | **Step 2** — create knowledge sources + a knowledge base, and run agentic retrieval. |
| `maf_rag.py` | **Step 3** — the MAF orchestrator agent (decompose → multi-search → rerank → synthesize). |
| `evals.py` | Model-graded evaluators (Azure AI Evaluation): groundedness, relevance, retrieval. |
| `compare.py` | **Step 4** — run both engines over every question and score recall / groundedness / relevance / retrieval / sub-queries / latency. |
| `fetch_docs.py` | Optional — pull real public docs to augment the synthetic corpus. |

## Prerequisites

- An **Azure AI Search** service (Basic tier or higher, **semantic ranker enabled**).
- An **Azure OpenAI** resource with an **embedding** deployment (default `text-embedding-3-small`,
  1536 dims) and a **vision-capable chat** deployment (default `gpt-4o-mini`) used for both the
  Foundry IQ planner and figure verbalization.
- The **APIM inference gateway** from Scenario 2 (for the MAF chat model).
- `make_figures.py` needs **matplotlib** + **pillow** (already in `requirements.txt`).
- Foundry IQ uses a **preview** Azure AI Search API. Install it to enable that path:
  `pip install --pre azure-search-documents` (otherwise the Foundry IQ column degrades and
  the MAF column still runs).

```powershell
cd rag-demo
python -m venv .venv ; .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## Configure

Values resolve as **env var > `infra/scenario-outputs.json` > default**. Minimum to set:

```powershell
# Azure AI Search
$env:AZURE_SEARCH_ENDPOINT = "https://<your-search>.search.windows.net"
$env:AZURE_SEARCH_API_KEY  = "<admin key>"          # omit to use DefaultAzureCredential

# Azure OpenAI (DIRECT plane: embeddings + Foundry IQ planner)
$env:AZURE_OPENAI_ENDPOINT          = "https://<your-aoai>.openai.azure.com"
$env:AZURE_OPENAI_API_KEY           = "<aoai key>"  # omit to use DefaultAzureCredential
$env:AZURE_OPENAI_EMBED_DEPLOYMENT  = "text-embedding-3-small"
$env:AZURE_OPENAI_CHAT_DEPLOYMENT   = "gpt-4o-mini"

# MAF chat model (GOVERNED plane: APIM inference gateway from Scenario 2)
$env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"   # picked up from scenario-outputs.json if present
$env:APIM_API_KEY     = "<apim subscription key>"
```

> If your embedding deployment isn't `text-embedding-3-small`, also set
> `AZURE_OPENAI_EMBED_MODEL` and `AZURE_OPENAI_EMBED_DIMENSIONS` to match (e.g. `3072` for
> `text-embedding-3-large`).

## Run

```powershell
python make_figures.py                 # 0b) render embedded figures (matplotlib)
python build_indexes.py --recreate     # 1) create indexes + verbalize figures + ingest corpus
python foundry_iq.py --setup           # 2) create knowledge sources + knowledge base
python maf_rag.py "Convert the HPX-450 to water-glycol — what do I need?"   # try MAF alone
python foundry_iq.py "Convert the HPX-450 to water-glycol — what do I need?" # try IQ alone
python compare.py                      # 4) side-by-side comparison + summary table
```

`compare.py` prints, per question, each engine's **recall** against the expected source docs,
model-graded **groundedness / relevance / retrieval** (1–5 LLM judge via Azure AI Evaluation),
how many **sub-queries** the planner fired, **latency**, and the answer — then a summary table.
Results are also written to `results.json` and `results.csv`.

## The APIM angle (what we integrate later)

This demo already separates the two model planes so the governance story is concrete:

- **MAF path** — the agent's chat model is the APIM inference gateway, so planner + synthesis
  tokens are already governed (quota, keys, observability). The retrieval calls hit Azure AI
  Search directly (same data plane as Foundry IQ).
- **Foundry IQ path** — the knowledge-base model calls Azure OpenAI **directly**; Foundry IQ
  does **not** support routing that planner/synthesis model through APIM today. That is the
  documented trade-off: managed convenience vs. full gateway governance.

"Integrate with APIM later" therefore mostly means formalizing the MAF plane (policies,
products, subscriptions) and, for the embedding/vectorizer, optionally pointing the index
vectorizer's `resource_url` at an APIM front door (supported for embeddings, **not** for the
IQ planner).
