"""
Real, model-graded evaluators for the comparison — the "data-based" part.

Uses the official **Azure AI Evaluation SDK** (azure-ai-evaluation) with an LLM judge
(gpt-4o-mini on the direct AOAI plane) to score each engine's answer on:

  * groundedness  — is the answer supported by the retrieved context? (1–5)
  * relevance     — does the answer address the question? (1–5)
  * retrieval     — how relevant/complete is the retrieved context for the query? (1–5)

Plus a deterministic, ground-truth metric computed in compare.py:

  * doc_recall    — fraction of expected source documents actually retrieved (0–1)

The judge authenticates keyless (DefaultAzureCredential) because the AOAI account has
local auth disabled. If the SDK or judge is unavailable, evaluate() returns NaNs and the
run still produces the deterministic metrics.
"""

import math

import config as cfg

_NAN = float("nan")


class Evaluators:
    """Lazily-constructed Azure AI Evaluation evaluators sharing one judge config."""

    def __init__(self) -> None:
        self.available = False
        self.error = ""
        self._groundedness = None
        self._relevance = None
        self._retrieval = None
        try:
            from azure.ai.evaluation import (
                GroundednessEvaluator,
                RelevanceEvaluator,
                RetrievalEvaluator,
            )

            model_config = {
                "azure_endpoint": cfg.AOAI_ENDPOINT,
                "azure_deployment": cfg.KB_CHAT_DEPLOYMENT,
                "api_version": cfg.AOAI_API_VERSION,
            }
            if cfg.AOAI_API_KEY:
                model_config["api_key"] = cfg.AOAI_API_KEY  # else keyless (DefaultAzureCredential)

            self._groundedness = GroundednessEvaluator(model_config)
            self._relevance = RelevanceEvaluator(model_config)
            self._retrieval = RetrievalEvaluator(model_config)
            self.available = True
        except Exception as exc:  # noqa: BLE001 - degrade to deterministic-only
            self.error = f"{type(exc).__name__}: {exc}"

    @staticmethod
    def _score(raw: dict, metric: str) -> float:
        """Pull a 1-5 score out of an evaluator result, tolerant of SDK quirks.

        Some evaluators (e.g. RetrievalEvaluator in azure-ai-evaluation 1.17.0)
        return the top-level ``<metric>`` / ``<metric>_score`` keys as NaN while the
        real numeric score lives nested under ``<metric>_properties.score``.
        """
        candidates = [
            raw.get(metric),
            raw.get(f"{metric}_score"),
            raw.get(f"gpt_{metric}"),
        ]
        props = raw.get(f"{metric}_properties")
        if isinstance(props, dict):
            candidates.append(props.get("score"))
        for v in candidates:
            if isinstance(v, (int, float)) and not math.isnan(float(v)):
                return float(v)
        return _NAN

    def evaluate(self, query: str, response: str, context: str) -> dict:
        """Return {groundedness, relevance, retrieval} scores (NaN on failure)."""
        out = {"groundedness": _NAN, "relevance": _NAN, "retrieval": _NAN}
        if not self.available or not response:
            return out
        try:
            r = self._groundedness(query=query, response=response, context=context or " ")
            out["groundedness"] = self._score(r, "groundedness")
        except Exception:  # noqa: BLE001
            pass
        try:
            r = self._relevance(query=query, response=response)
            out["relevance"] = self._score(r, "relevance")
        except Exception:  # noqa: BLE001
            pass
        try:
            r = self._retrieval(query=query, context=context or " ")
            out["retrieval"] = self._score(r, "retrieval")
        except Exception:  # noqa: BLE001
            pass
        return out
