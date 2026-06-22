"""
Optional — fetch a few REAL public manufacturing documents to augment the synthetic corpus.

The demo ships with a self-contained synthetic Fabrikam corpus under data/docs/ so it runs
offline. If you'd rather index real public material (e.g. a public machine-tool safety guide
or an industrial-pump manual), add URLs to SOURCES below and run this script. Fetched pages
are saved as markdown-ish text into the chosen domain folder and picked up automatically by
build_indexes.py.

Usage:
    python fetch_docs.py
"""

import os
import re

import httpx

import config as cfg

# (url, domain, doc_id, title). Add your own public, redistributable sources here.
SOURCES: list[tuple[str, str, str, str]] = [
    # ("https://example.com/public-pump-manual.txt", "maintenance-sops", "ext-pump-manual",
    #  "Public Industrial Pump Maintenance Manual"),
]

_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"\n{3,}")


def _to_text(raw: str) -> str:
    text = _TAG.sub("", raw)
    return _WS.sub("\n\n", text).strip()


def main() -> None:
    if not SOURCES:
        print("No SOURCES configured. Edit fetch_docs.py and add public document URLs.")
        print("The demo already works with the synthetic corpus under data/docs/.")
        return
    for url, domain, doc_id, title in SOURCES:
        folder = os.path.join(cfg.DOCS_DIR, domain)
        os.makedirs(folder, exist_ok=True)
        resp = httpx.get(url, timeout=30.0, follow_redirects=True)
        resp.raise_for_status()
        body = _to_text(resp.text)
        path = os.path.join(folder, f"{doc_id}.md")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(f"---\ndoc_id: {doc_id}\ntitle: {title}\ndomain: {domain}\n---\n\n{body}\n")
        print(f"  saved {path}  ({len(body)} chars)")


if __name__ == "__main__":
    main()
