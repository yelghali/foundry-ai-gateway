"""
Dummy A2A (Agent2Agent) agent — standard-library only, zero dependencies.

Implements just enough of the A2A protocol (https://a2a-protocol.org) to be
governed by a gateway and called by a client:

  GET  /.well-known/agent-card.json   -> the AgentCard (discovery)
  GET  /.well-known/agent.json        -> same (legacy discovery path)
  POST /                              -> JSON-RPC 2.0 "message/send" (a.k.a. "SendMessage")

It is intentionally tiny so it can run inside a stock `python:3.12-slim`
container with NO pip install (instant, reliable startup). The "specialist"
just returns canned advice that echoes the caller's question — enough to prove
the request flowed through the gateway end to end.

Env:
  PORT             listening port (default 8080)
  A2A_PUBLIC_URL   url advertised in the agent card (default "/")
  A2A_FORWARD_URL  optional. When set, this agent acts as a host-root SHIM: instead of
                   answering message/send locally it forwards the JSON-RPC body to this
                   URL (e.g. a LiteLLM A2A gateway endpoint) and relays the response.
                   The agent card is still served locally at the host root so a managed
                   client (Foundry RemoteA2A) can discover it; the actual agent-to-agent
                   message leg then flows THROUGH the forward target.
  A2A_FORWARD_AUTH optional. Value for the Authorization header sent on the forwarded
                   request (e.g. "Bearer sk-..."), so the shim authenticates to the
                   gateway on the client's behalf.
"""

import json
import os
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
PUBLIC_URL = os.environ.get("A2A_PUBLIC_URL", "/")
# When set, run as a host-root shim that forwards message/send to this gateway URL
# (the card is still served locally so a managed A2A client can discover the agent).
FORWARD_URL = os.environ.get("A2A_FORWARD_URL", "").strip()
FORWARD_AUTH = os.environ.get("A2A_FORWARD_AUTH", "").strip()

AGENT_CARD = {
    "name": "Dummy Specialist Agent",
    "description": "A tiny demo A2A agent that returns canned expert advice for any question.",
    "version": "1.0.0",
    "protocolVersion": "0.3.0",
    "url": PUBLIC_URL,
    "preferredTransport": "JSONRPC",
    "capabilities": {"streaming": False, "pushNotifications": False},
    "defaultInputModes": ["text/plain"],
    "defaultOutputModes": ["text/plain"],
    "skills": [
        {
            "id": "expert-advice",
            "name": "Expert Advice",
            "description": "Returns a short piece of canned expert advice for any question.",
            "tags": ["demo", "advice"],
            "examples": ["What is an AI gateway?", "Should I put a gateway in front of my agents?"],
        }
    ],
}


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _extract_text(params: dict) -> str:
    """Pull the user's text out of an A2A message envelope."""
    message = (params or {}).get("message", {}) or {}
    parts = message.get("parts", []) or []
    chunks = []
    for part in parts:
        if isinstance(part, dict) and part.get("kind") in (None, "text") and "text" in part:
            chunks.append(str(part["text"]))
    return " ".join(chunks).strip()


def _specialist_answer(question: str) -> str:
    if not question:
        question = "(no question provided)"
    return (
        f"[Dummy Specialist] You asked: \"{question}\". "
        "My expert advice: always place an AI gateway in front of your models AND your agents "
        "so a single control plane handles auth, quotas, logging and routing."
    )


def _make_task_result(request_id, question: str) -> dict:
    # A2A "message/send" may return either a Message or a Task. We reply with a
    # synchronous Message (the simplest result kind), which every A2A client we target
    # — including the Foundry Agent Service A2A tool — accepts. (Returning a completed
    # Task object instead caused the Foundry runtime to fail processing the reply.)
    answer = _specialist_answer(question)
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {
            "kind": "message",
            "role": "agent",
            "messageId": f"msg-{uuid.uuid4().hex}",
            "parts": [{"kind": "text", "text": answer}],
        },
    }


def _error(request_id, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def _forward(raw_body: bytes) -> tuple[int, bytes]:
    """Relay a JSON-RPC request to the configured forward target (e.g. LiteLLM A2A).

    Returns (status_code, response_bytes). The response is passed back to the caller
    verbatim, so the gateway's own A2A reply (a Message-kind result) flows straight
    through this host-root shim.
    """
    req = urllib.request.Request(FORWARD_URL, data=raw_body, method="POST")
    req.add_header("Content-Type", "application/json")
    if FORWARD_AUTH:
        req.add_header("Authorization", FORWARD_AUTH)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


class Handler(BaseHTTPRequestHandler):
    server_version = "DummyA2A/1.0"
    # Speak HTTP/1.1 so clients that use keep-alive / chunked uploads (e.g. .NET
    # HttpClient, which the Foundry Agent Service A2A tool uses) are framed correctly.
    protocol_version = "HTTP/1.1"

    def _read_body(self) -> bytes:
        """Read the request body, honouring chunked transfer-encoding.

        Some A2A clients (notably .NET HttpClient) send the JSON-RPC body with
        ``Transfer-Encoding: chunked`` and no ``Content-Length``. The stdlib handler
        does not de-chunk for us, so a naive ``Content-Length`` read returns an empty
        body and the request looks like it has no ``method``.
        """
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            chunks = []
            while True:
                size_line = self.rfile.readline()
                if not size_line:
                    break
                try:
                    size = int(size_line.strip().split(b";", 1)[0], 16)
                except ValueError:
                    break
                if size == 0:
                    self.rfile.readline()  # consume the trailing CRLF
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()  # consume the CRLF after each chunk
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length else b""

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (http.server API)
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/.well-known/agent-card.json", "/.well-known/agent.json"):
            self._send_json(200, AGENT_CARD)
        elif path == "/":
            self._send_json(200, {"status": "ok", "agent": AGENT_CARD["name"]})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802 (http.server API)
        try:
            raw = self._read_body()
            req = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, _error(None, -32700, "Parse error"))
            return
        if not isinstance(req, dict):
            self._send_json(200, _error(None, -32600, "Invalid Request"))
            return

        request_id = req.get("id")
        method = req.get("method", "")
        # Accept the slash form and the PascalCase SDK alias.
        if method in ("message/send", "SendMessage", "message/stream"):
            if FORWARD_URL:
                # Host-root shim: forward the call to the gateway (e.g. LiteLLM A2A)
                # with the Authorization header injected, and relay its reply verbatim.
                status, body = _forward(raw)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                question = _extract_text(req.get("params", {}))
                self._send_json(200, _make_task_result(request_id, question))
        else:
            self._send_json(200, _error(request_id, -32601, f"Method not found: {method}"))

    def log_message(self, fmt, *args):  # keep container logs readable
        print("a2a %s - %s" % (self.address_string(), fmt % args), flush=True)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Dummy A2A agent listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
