"""OpenAI-compatible shim in front of Ollama for OpenChoreo's AI agents.

The agents (LangChain ``create_agent`` + ``ProviderStrategy``) send ``tools``
and ``response_format: json_schema`` in the same request, expecting OpenAI's
behaviour: the model either calls a tool or returns the final structured
answer. Ollama turns ``response_format`` into a grammar for the whole
generation, so tool calls can never be emitted and the model answers blind.

For such requests this shim:
  1. asks Ollama with the tools and without the schema;
  2. returns tool calls as they are;
  3. otherwise asks again without tools and with the schema, so the model
     formats its answer as the expected JSON.
Everything else is proxied unchanged. Responses to streaming requests in the
split path are sent as a single SSE chunk (tokens are not streamed there).
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("UPSTREAM", "http://ollama.internal:11434").rstrip("/")
TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "600"))
PORT = int(os.environ.get("PORT", "8080"))

FORMAT_INSTRUCTION = (
    "Now return your previous answer as JSON matching the required response "
    "schema, keeping its substance and language. Text fields meant for the user "
    "(such as a message, summary or description) must contain readable Markdown "
    "prose, never JSON or code blocks wrapping JSON. Do not call tools."
)


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, file=sys.stderr, flush=True)


def upstream_json(path, body, headers):
    req = urllib.request.Request(
        UPSTREAM + path, json.dumps(body).encode(), headers, method="POST"
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
        return json.load(res)


def require_all_properties(node):
    """OpenAI strict-mode semantics: every object property is required.

    Pydantic marks fields with defaults as optional in the JSON schema, so
    Ollama's grammar lets the model drop them, including discriminator fields
    like ``type: Literal["log"] = "log"``, and the agent then fails to parse the
    tagged union. OpenAI's strict structured outputs require them all.
    """
    if isinstance(node, dict):
        props = node.get("properties")
        if isinstance(props, dict) and props:
            node["required"] = list(props)
        for value in node.values():
            require_all_properties(value)
    elif isinstance(node, list):
        for value in node:
            require_all_properties(value)
    return node


def to_sse(completion, include_usage):
    """One OpenAI chat.completion -> equivalent chat.completion.chunk events."""
    choice = completion["choices"][0]
    message = choice.get("message", {})
    delta = {"role": "assistant", "content": message.get("content") or ""}
    if message.get("tool_calls"):
        delta["tool_calls"] = [
            {**call, "index": i} for i, call in enumerate(message["tool_calls"])
        ]
    base = {k: completion.get(k) for k in ("id", "created", "model", "system_fingerprint")}
    base["object"] = "chat.completion.chunk"
    events = [
        {**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
        {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": choice.get("finish_reason")}]},
    ]
    if include_usage and completion.get("usage"):
        events.append({**base, "choices": [], "usage": completion["usage"]})
    return "".join(f"data: {json.dumps(e)}\n\n" for e in events) + "data: [DONE]\n\n"


def split_tools_and_schema(body, headers):
    """Tool round first; schema round only for a final (non-tool) answer."""
    with_tools = {k: v for k, v in body.items() if k not in ("response_format", "stream", "stream_options")}
    first = upstream_json("/v1/chat/completions", with_tools, headers)
    message = first["choices"][0]["message"]
    if message.get("tool_calls"):
        log("tool round: " + ", ".join(
            f"{c['function']['name']}({c['function'].get('arguments', '')[:120]})" for c in message["tool_calls"]))
        last = body["messages"][-1]
        if last.get("role") == "tool":
            log(f"  previous tool result: {str(last.get('content'))[:200]!r}")
        return first

    log(f"answer round, draft: {(message.get('content') or '')[:160]!r}")
    drop = ("tools", "tool_choice", "parallel_tool_calls", "stream", "stream_options")
    formatted = {k: v for k, v in body.items() if k not in drop}
    formatted["response_format"] = require_all_properties(json.loads(json.dumps(body["response_format"])))
    formatted["messages"] = body["messages"] + [
        {"role": "assistant", "content": message.get("content") or ""},
        {"role": "user", "content": FORMAT_INSTRUCTION},
    ]
    second = upstream_json("/v1/chat/completions", formatted, headers)
    log("final round: structured answer")
    return second


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, status, payload, content_type="application/json"):
        data = payload if isinstance(payload, bytes) else payload.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _proxy(self, body=None):
        headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
        req = urllib.request.Request(UPSTREAM + self.path, body, headers, method=self.command)
        try:
            res = urllib.request.urlopen(req, timeout=TIMEOUT)
        except urllib.error.HTTPError as err:
            return self._send(err.code, err.read())
        self.send_response(res.status)
        self.send_header("Content-Type", res.headers.get("Content-Type", "application/json"))
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        while chunk := res.read1(65536) if hasattr(res, "read1") else res.read(65536):
            self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, b'{"ok":true}')
        self._proxy()

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._proxy(raw)
        body = json.loads(raw or b"{}")
        if not (body.get("tools") and body.get("response_format")):
            return self._proxy(raw)
        try:
            completion = split_tools_and_schema(body, {"Content-Type": "application/json"})
        except urllib.error.HTTPError as err:
            return self._send(err.code, err.read())
        except Exception as err:  # surface upstream failures as OpenAI-style errors
            log(f"error: {err!r}")
            return self._send(502, json.dumps({"error": {"message": str(err), "type": "upstream_error"}}))
        if body.get("stream"):
            include_usage = bool((body.get("stream_options") or {}).get("include_usage"))
            return self._send(200, to_sse(completion, include_usage), "text/event-stream")
        self._send(200, json.dumps(completion))


if __name__ == "__main__":
    log(f"ollama shim on :{PORT} -> {UPSTREAM}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
