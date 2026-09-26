#!/usr/bin/env python3
"""Build the canonical ROLLBACK admin request (twow-repo#366 part 5, rollback guard).

A ROLLBACK makes a *new* roster version whose members are exactly those of an earlier
version (core PersistentActiveRoster.cpp: after.guids = historical.guids). Rolling the
154 roster back to version 3 therefore restores the 136 ordinals 1-136 as the active
roster; bots 137-154 simply stay offline and nobody's progress is touched, because
progress lives in the characters, not in the roster version.

Same canonical serialization as make_expand_request.py (SerializeAdminRequest): LF, UTF-8
without BOM, unpadded base64url, empty add/remove/replace lists, rollback_version_id set.

    python3 make_rollback_request.py --expected-current-version 4 --rollback-version 3 \
        --target-count 136 --actor <who> --reason <why> --out rollback-request.txt
"""
import argparse
import hashlib
import sys
import unicodedata
import uuid

from make_expand_request import UUID_V4, b64url


def build(expected_current, rollback_version, target_count, operation_id, actor, reason):
    if not UUID_V4.match(operation_id):
        raise ValueError("operation id must be a canonical lowercase UUIDv4")
    if not actor:
        raise ValueError("actor must not be empty")
    for label, text in (("actor", actor), ("reason", reason)):
        if unicodedata.normalize("NFC", text) != text:
            raise ValueError(f"{label} must be NFC")
    if min(expected_current, rollback_version, target_count) <= 0 or rollback_version >= expected_current:
        raise ValueError("need 0 < rollback_version < expected_current and a positive target count")
    lines = [
        "ssc-rndbot-admin-request-v1",
        "schema_version=1",
        f"operation_id={operation_id}",
        "operation_type=ROLLBACK",
        f"expected_current_version_id={expected_current}",
        f"actor_utf8_b64url={b64url(actor)}",
        f"reason_utf8_b64url={b64url(reason)}",
        f"requested_target_count={target_count}",
        "add_count=0",
        "remove_count=0",
        "replace_count=0",
        f"rollback_version_id={rollback_version}",
    ]
    return ("\n".join(lines) + "\n").encode("utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expected-current-version", type=int, required=True)
    ap.add_argument("--rollback-version", type=int, required=True)
    ap.add_argument("--target-count", type=int, required=True, help="member count of the rollback version")
    ap.add_argument("--operation-id", default=None)
    ap.add_argument("--actor", required=True)
    ap.add_argument("--reason", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    operation_id = args.operation_id or str(uuid.uuid4())
    try:
        data = build(args.expected_current_version, args.rollback_version, args.target_count,
                     operation_id, args.actor, args.reason)
    except ValueError as e:
        sys.exit(str(e))
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"operation_id={operation_id}")
    print(f"request_sha256={hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
