#!/usr/bin/env python3
r"""A deterministic stand-in for a language model. NOT a model, NOT a mock of us.

WHY THIS EXISTS
---------------
CI has no GPU, no model weights and no API key, so nothing in the stack can
answer a chat-completions call. Without an answer the dialogue path cannot be
exercised past the point where it makes the HTTP request, and "we sent a request
somewhere" is not evidence that a reply reaches anyone.

So this serves the one route our LLM consumers speak - OpenAI's
`POST .../chat/completions` - and always answers with the same sentence.

WHAT IT IS DELIBERATELY NOT
---------------------------
It is not a mock of `services/bot-brain`, of `mod-playerbots`, or of any code
under test. Every byte between the caller and this process is the real thing:
the real HTTP client, the real request construction, the real timeout, the real
response parsing, the real validation, the real circuit breaker, the real token
budget and the real silence rules. Only the *model* is replaced, and the model
is the one component that could never run in CI anyway.

That substitution does not weaken the test, because the test is about the
plumbing carrying a reply end to end. A stub that says the same thing every time
is in fact BETTER than a real model for that purpose: the assertion can be an
exact string match rather than "something plausible came back", so a reply that
was mangled, truncated, re-encoded, re-addressed or silently dropped shows up as
a failure instead of being written off as the model having a different opinion
today. The check reads the expected sentence back out of THIS process
(`GET /_stub/stats`) rather than hardcoding it, so a pass means the sentence
travelled - not that two copies of a constant agree.

WHAT IT REFUSES TO DO
---------------------
It emits no `usage` object. bot-brain's token budget verifies provider
accounting and latches shut on an inconsistency, after which every later call is
silenced with `budget_exhausted`. A stub that invented token counts could
therefore turn itself into a false failure a long way from its cause. Omitting
`usage` is the honest answer: this thing has no tokens.

TWO CONSUMERS, TWO SHAPES, ONE PROCESS
--------------------------------------
The body differs by path, because the two consumers read it differently and both
are real code this file does not get to change:

  * `/v1/chat/completions` puts the sentence in `choices[0].message.content`
    verbatim. That is what a plain OpenAI-compatible client expects, and what
    mod-playerbots' `PlayerbotLLMInterface::GenerateDebugResponse` parses.

  * `/dialogue/v1/chat/completions` puts a JSON DOCUMENT there instead:
    `{"reply": "<sentence>"}`. bot-brain's dialogue planner requires the model's
    content to be an object with exactly that one key and silences anything else
    as `filtered`, so a plain sentence there would look like a plumbing failure
    and would not be one. Point `BOT_BRAIN_LLM_BASE_URL` at
    `http://llm-stub:8099/dialogue/v1`.

Both bodies also carry a top-level `"text"` field. mod-playerbots' in-world chat
path does not parse JSON at all - it regex-searches the raw body from
`AiPlayerbot.LLMResponseStartPattern`, whose compiled default is `("text":\s*")`
(PlayerbotAIConfig.cpp), a KoboldCPP shape rather than an OpenAI one, and the
rendered aiplayerbot.conf leaves that default alone. The field costs nothing and
means a consumer arriving on that path needs no change here.

THE SENTENCE IS LOAD-BEARING
----------------------------
bot-brain silences a reply that clips to under 24 bytes. The default below is
comfortably longer, and says what it is: a stub reply that ever reached a live
realm would be unmistakable in a log rather than passing for a bot's.

NEVER RUN THIS IN PRODUCTION.
"""

import json
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The whole model. One sentence, forever.
REPLY = os.environ.get("LLM_STUB_REPLY", "Stub model speaking; always this exact line.")

# Bounded so a runaway caller cannot make this the thing that fills the runner.
MAX_BODY = 1 << 20

_lock = threading.Lock()
_stats = {
    "chat_completions": 0,
    "last_seen_utc": None,
    "last_model": None,
    "last_messages": 0,
    "reply": REPLY,
}


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.rstrip("/")
        if path in ("/_stub/stats", "/_stub"):
            with _lock:
                self._send(200, dict(_stats))
            return
        if path == "/healthz":
            self._send(200, {"status": "ok", "stub": True})
            return
        self._send(404, {"error": {"message": "stub serves chat/completions only"}})

    def do_POST(self):
        # Matched by SUFFIX, not by whole path: a caller appends
        # "/chat/completions" to whatever base URL it was configured with, and
        # this process must not care what that prefix was - only whether the
        # prefix asked for the dialogue shape.
        path = self.path.rstrip("/")
        if not path.endswith("/chat/completions"):
            self._send(404, {"error": {"message": "stub serves chat/completions only"}})
            return
        dialogue_shape = path.startswith("/dialogue/")

        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            self._send(413, {"error": {"message": "body too large for a stub"}})
            return
        raw = self.rfile.read(length) if length else b""

        model = "stub-model"
        messages = 0
        try:
            req = json.loads(raw.decode("utf-8"))
            model = req.get("model") or model
            messages = len(req.get("messages") or [])
        except Exception:
            # A body this cannot parse is still answered. The point is to prove
            # the CALLER's path; refusing here would only ever produce a
            # confusing failure a long way from its cause.
            pass

        with _lock:
            _stats["chat_completions"] += 1
            _stats["last_seen_utc"] = _now()
            _stats["last_model"] = model
            _stats["last_messages"] = messages

        content = json.dumps({"reply": REPLY}, ensure_ascii=False) if dialogue_shape else REPLY
        self._send(200, {
            "id": "stub-completion",
            "object": "chat.completion",
            "created": 0,
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }],
            "text": REPLY,
            # No "usage". See the module docstring.
        })

    def log_message(self, fmt, *args):
        sys.stderr.write("llm-stub %s - %s\n" % (self.address_string(), fmt % args))


def main():
    listen = os.environ.get("LLM_STUB_LISTEN", "0.0.0.0:8099")
    host, _, port = listen.rpartition(":")
    server = ThreadingHTTPServer((host or "0.0.0.0", int(port)), Handler)
    sys.stderr.write("llm-stub listening on %s, reply=%r\n" % (listen, REPLY))
    server.serve_forever()


if __name__ == "__main__":
    main()
