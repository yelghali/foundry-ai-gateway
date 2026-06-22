"""
Shared helpers for the RAG demo: ANSI colors, client factories, and the tiny
front-matter + chunking utilities used to load the manufacturing corpus.

Real-world docs embed images (performance curves, zone diagrams, control-loop
trends). We make that visual content retrievable the way production multimodal-RAG
pipelines do: at ingest, each embedded figure is **verbalized** by a vision model
(GPT-4o-mini) into precise text, which is then chunked, embedded and indexed
alongside the prose. Both engines (MAF and Foundry IQ) query the same indexes, so
they compete on the same multimodal corpus.
"""

import base64
import glob
import os
import re
import sys

import config as cfg

# --- Pretty colors (ANSI) ------------------------------------------------------
if os.name == "nt":
    os.system("")
_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None

BOLD = "1"; DIM = "2"; RED = "31"; GREEN = "32"; YELLOW = "33"
BLUE = "34"; MAGENTA = "35"; CYAN = "36"; GREY = "90"


def c(text: str, *codes: str) -> str:
    if not _COLOR or not codes:
        return text
    return f"\033[{';'.join(codes)}m{text}\033[0m"


def header(title: str, lines=()) -> None:
    print(c("═" * 80, MAGENTA))
    print(c(f" {title}", BOLD, MAGENTA))
    for ln in lines:
        print(c(f" {ln}", DIM))
    print(c("═" * 80, MAGENTA))


def section(title: str) -> None:
    print()
    print(c("─" * 80, CYAN))
    print(c(f" {title}", BOLD, CYAN))
    print(c("─" * 80, CYAN))


# --- Credentials / clients -----------------------------------------------------
def search_credential():
    """Key credential if AZURE_SEARCH_API_KEY is set, else DefaultAzureCredential."""
    if cfg.SEARCH_API_KEY:
        from azure.core.credentials import AzureKeyCredential
        return AzureKeyCredential(cfg.SEARCH_API_KEY)
    from azure.identity import DefaultAzureCredential
    return DefaultAzureCredential()


def aoai_client():
    """Azure OpenAI client (DIRECT plane) for embeddings + any local LLM calls."""
    from openai import AzureOpenAI
    if not cfg.AOAI_ENDPOINT:
        raise SystemExit("Missing AZURE_OPENAI_ENDPOINT for embeddings / Foundry IQ model.")
    if cfg.AOAI_API_KEY:
        return AzureOpenAI(
            azure_endpoint=cfg.AOAI_ENDPOINT,
            api_key=cfg.AOAI_API_KEY,
            api_version=cfg.AOAI_API_VERSION,
        )
    from azure.identity import DefaultAzureCredential, get_bearer_token_provider
    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
    )
    return AzureOpenAI(
        azure_endpoint=cfg.AOAI_ENDPOINT,
        azure_ad_token_provider=token_provider,
        api_version=cfg.AOAI_API_VERSION,
    )


def embed_texts(texts: list[str]) -> list[list[float]]:
    """Embed a batch of texts with the configured AOAI embedding deployment."""
    client = aoai_client()
    resp = client.embeddings.create(
        model=cfg.EMBED_DEPLOYMENT,
        input=texts,
        dimensions=cfg.EMBED_DIMENSIONS,
    )
    return [d.embedding for d in resp.data]


# --- Image verbalization (multimodal ingest) -----------------------------------
_VERBALIZE_PROMPT = (
    "You are transcribing a figure from an industrial manufacturing document so it can "
    "be retrieved by a search engine. Describe the figure precisely: state its type "
    "(curve, schematic, plan view, trend, table), then transcribe EVERY axis label with "
    "units, every annotated value, callout, setpoint, shaded band, radius, and numeric "
    "data point that is visible. Report peaks/intersections with their coordinates. Do "
    "NOT invent values that are not shown. Keep it factual and dense; no preamble."
)


def _image_data_url(path: str) -> str:
    with open(path, "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode("ascii")
    return f"data:image/png;base64,{b64}"


def verbalize_image(path: str, context: str = "") -> str:
    """Return a dense textual transcription of a figure (cached next to the image).

    The caption is cached as ``<image>.caption.txt`` so rebuilds are deterministic and
    don't re-spend vision tokens. Delete the sidecar to force re-verbalization.
    """
    cache = f"{path}.caption.txt"
    if os.path.exists(cache):
        with open(cache, "r", encoding="utf-8") as fh:
            cached = fh.read().strip()
        if cached:
            return cached

    client = aoai_client()
    user_text = _VERBALIZE_PROMPT
    if context:
        user_text += f"\n\nDocument context: {context}"
    resp = client.chat.completions.create(
        model=cfg.KB_CHAT_DEPLOYMENT,
        temperature=0,
        messages=[
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_text},
                    {"type": "image_url", "image_url": {"url": _image_data_url(path)}},
                ],
            }
        ],
    )
    caption = (resp.choices[0].message.content or "").strip()
    if caption:
        with open(cache, "w", encoding="utf-8") as fh:
            fh.write(caption)
    return caption


# --- Corpus loading + chunking -------------------------------------------------
_FRONT_MATTER = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)
_IMAGE_REF = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")


def _parse_front_matter(text: str) -> tuple[dict, str]:
    meta: dict = {}
    m = _FRONT_MATTER.match(text)
    body = text
    if m:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, _, v = line.partition(":")
                meta[k.strip()] = v.strip()
        body = text[m.end():]
    return meta, body


def _chunk(body: str, max_chars: int = 1100, overlap: int = 150) -> list[str]:
    """Paragraph-aware char chunking; keeps headings with their following text."""
    paras = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]
    chunks: list[str] = []
    buf = ""
    for p in paras:
        if len(buf) + len(p) + 2 <= max_chars:
            buf = f"{buf}\n\n{p}" if buf else p
        else:
            if buf:
                chunks.append(buf)
            buf = (buf[-overlap:] + "\n\n" + p) if buf and overlap else p
            while len(buf) > max_chars:
                chunks.append(buf[:max_chars])
                buf = buf[max_chars - overlap:]
    if buf:
        chunks.append(buf)
    return chunks


def load_domain_chunks(domain: str) -> list[dict]:
    """Return chunk records for every document in a domain folder.

    Prose is paragraph-chunked as usual. Each embedded image is verbalized by a vision
    model and added as its own searchable chunk (same doc_id), so figure-only facts
    become retrievable.
    """
    folder = os.path.join(cfg.DOCS_DIR, domain)
    records: list[dict] = []
    for path in sorted(glob.glob(os.path.join(folder, "*.md"))):
        doc_dir = os.path.dirname(path)
        with open(path, "r", encoding="utf-8") as fh:
            meta, body = _parse_front_matter(fh.read())
        doc_id = meta.get("doc_id") or os.path.splitext(os.path.basename(path))[0]
        title = meta.get("title", doc_id)
        product = meta.get("product", "")

        # Pull image references out, then leave a readable placeholder in the prose.
        images = _IMAGE_REF.findall(body)  # list of (alt, rel_path)
        prose = _IMAGE_REF.sub(lambda m: f"(see figure: {m.group(1)})", body)

        n = 0
        for chunk in _chunk(prose):
            records.append({
                "id": f"{doc_id}-{n}",
                "doc_id": doc_id,
                "title": title,
                "domain": domain,
                "product": product,
                "source": os.path.basename(path),
                "chunk": chunk,
                "page_number": n,
            })
            n += 1

        for alt, rel in images:
            img_path = os.path.normpath(os.path.join(doc_dir, rel.strip()))
            if not os.path.exists(img_path):
                print(c(f"  ! figure missing, skipped: {rel}", YELLOW))
                continue
            try:
                caption = verbalize_image(img_path, context=f"{title} — {alt}")
            except Exception as exc:  # noqa: BLE001 - degrade to alt text
                print(c(f"  ! verbalize failed for {os.path.basename(img_path)}: {exc}", YELLOW))
                caption = alt
            print(c(f"  figure verbalized: {os.path.basename(img_path)}", GREEN))
            records.append({
                "id": f"{doc_id}-fig{n}",
                "doc_id": doc_id,
                "title": title,
                "domain": domain,
                "product": product,
                "source": os.path.basename(img_path),
                "chunk": f"[FIGURE — {alt}] (from {title})\n{caption}",
                "page_number": n,
            })
            n += 1
    return records
