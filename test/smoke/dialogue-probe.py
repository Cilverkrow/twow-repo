#!/usr/bin/env python3
"""The HTTP client 60-bot-dialogue.sh uses. Stdlib only, prints shell-readable
`key=value` lines on stdout and nothing else.

WHY A SEPARATE FILE, AND WHY IT RUNS IN A CONTAINER.

The smoke suite is POSIX `sh` and assumes almost nothing about the host: there
is no guaranteed `curl`, no `jq`, and lib.sh's `dbq` already establishes the
pattern of doing the work INSIDE the compose project rather than on whatever
machine happens to be driving it. bot-brain is a `scratch` image with no shell
and the worldserver image ships neither curl nor python, so the only container
in the project with an HTTP client is the stub - which is also the only one on
the project network that can address `bot-brain:8085` by service name with no
published port.

So 60-bot-dialogue.sh reads THIS file and hands it to a throwaway container
built from the stub's image, as `docker compose run --rm -T --no-deps llm-stub
python3 -c "<this file>" <mode> <args...>`. A throwaway rather than `exec` into
the running stub, because one of the things the check proves is what happens
when the stub is STOPPED, and a client that dies with the server it is
interrogating could not make that assertion at all.

It is passed with `-c` rather than piped on stdin because `compose run -T` with
redirected stdin does not deliver EOF on a Docker Desktop host: `python3 -`
blocks there forever and the check times out instead of failing. Under `-c`,
argv[0] is "-c" and the mode is still argv[1], so nothing below changes.

Output contract: one `key=value` per line, values may contain spaces, never
newlines (they are replaced). A key that has no value is printed empty rather
than omitted, so the caller never has to distinguish "absent" from "unset".
"""

import json
import sys
import urllib.error
import urllib.request


def emit(key, value):
    if value is None:
        value = ""
    if isinstance(value, bool):
        value = "true" if value else "false"
    text = str(value).replace("\r", " ").replace("\n", " ")
    sys.stdout.write("%s=%s\n" % (key, text))


def fetch(url, payload=None, timeout=20):
    """Returns (status, decoded-json-or-None, raw-text). Never raises for an
    HTTP status: a 404 and a 409 are both answers this check has to reason
    about, and turning them into exceptions would only mean catching them."""
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", "replace")
        status = err.code
    except Exception as err:                       # connection refused, DNS, timeout
        return 0, None, "transport error: %s" % err
    try:
        return status, json.loads(raw), raw
    except ValueError:
        return status, None, raw


def main(argv):
    mode = argv[1]

    if mode == "stub-stats":
        status, body, raw = fetch(argv[2].rstrip("/") + "/_stub/stats")
        emit("http_status", status)
        emit("count", (body or {}).get("chat_completions", ""))
        emit("reply", (body or {}).get("reply", ""))
        if body is None:
            emit("raw", raw[:400])
        return 0

    if mode == "health":
        status, body, raw = fetch(argv[2].rstrip("/") + "/healthz")
        emit("http_status", status)
        emit("contract_version", (body or {}).get("contract_version", ""))
        if body is None:
            emit("raw", raw[:400])
        return 0

    if mode == "dialogue":
        base, version, speaker, message = argv[2], argv[3], argv[4], argv[5]
        payload = {
            "contract_version": version,
            "request_id": "smoke-60-bot-dialogue",
            # A realm and a guid that are merely non-zero. The check is about
            # the reply travelling, and bot-brain deliberately never resolves a
            # bot id against the database - it only refuses to re-address one.
            "bot": {"realm": 1, "guid": 1},
            "channel": "whisper",
            "speaker": "player",
            "speaker_name": speaker,
            "message": message,
            "deadline_ms": 15000,
        }
        status, body, raw = fetch(base.rstrip("/") + "/v1/dialogue", payload)
        emit("http_status", status)
        if body is None:
            emit("spoke", "")
            emit("reply", "")
            emit("reason", "")
            emit("code", "")
            emit("raw", raw[:400])
            return 0
        emit("spoke", body.get("spoke", ""))
        emit("reply", body.get("reply", ""))
        emit("reason", body.get("reason", ""))
        # The 4xx error bodies carry `code`, not `reason`; printing both means
        # the caller reports what actually came back rather than guessing.
        emit("code", body.get("code", ""))
        emit("message", body.get("message", ""))
        return 0

    sys.stderr.write("unknown mode: %s\n" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
