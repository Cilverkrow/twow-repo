#!/usr/bin/env python3
"""Build the canonical EXPAND admin request for a roster CSV range (#366 A2).

Writes the exact bytes that the core's SerializeAdminRequest() produces for an
EXPAND (modules/mod-playerbots/src/playerbot/PersistentActiveRoster.cpp,
ssc-rndbot-admin-request-v1, ADR-0011): LF only, UTF-8 without BOM, unpadded
base64url for actor/reason, 10-digit add rows numbered from 1 in ordinal order.
It touches no database; the file is applied later with the local console command
`rndbot roster apply <absolute-path>` in maintenance mode.

    python3 make_expand_request.py --csv v4-272-roster-plan.csv --ordinals 137-272 \
        --expected-current-version 3 --actor <who> --reason <why> --out request.txt

Without --operation-id a fresh UUIDv4 is generated; keep the printed
request_sha256 for the approval, since replaying the same operation id with other
bytes fails closed in the core.
"""
import argparse
import base64
import csv
import hashlib
import re
import sys
import unicodedata
import uuid

UUID_V4 = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


def b64url(text):
    return base64.urlsafe_b64encode(text.encode("utf-8")).decode("ascii").rstrip("=")


def ten(value):
    if not 0 < value <= 0xFFFFFFFF:
        raise ValueError(f"out of range: {value}")
    return f"{value:010d}"


def build(guids, expected_current, target_count, operation_id, actor, reason):
    if not UUID_V4.match(operation_id):
        raise ValueError("operation id must be a canonical lowercase UUIDv4")
    for label, text in (("actor", actor), ("reason", reason)):
        if unicodedata.normalize("NFC", text) != text:
            raise ValueError(f"{label} must be NFC")
    if not actor:
        raise ValueError("actor must not be empty")
    if len(set(guids)) != len(guids) or not all(g > 0 for g in guids):
        raise ValueError("add GUIDs must be unique and positive")
    lines = [
        "ssc-rndbot-admin-request-v1",
        "schema_version=1",
        f"operation_id={operation_id}",
        "operation_type=EXPAND",
        f"expected_current_version_id={expected_current}",
        f"actor_utf8_b64url={b64url(actor)}",
        f"reason_utf8_b64url={b64url(reason)}",
        f"requested_target_count={target_count}",
        f"add_count={len(guids)}",
    ]
    lines += [f"add\t{ten(i)}\t{ten(g)}" for i, g in enumerate(guids, start=1)]
    lines += ["remove_count=0", "replace_count=0", "rollback_version_id=null"]
    return ("\n".join(lines) + "\n").encode("utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--ordinals", required=True, help="from-to, inclusive; the rows to add")
    ap.add_argument("--expected-current-version", type=int, required=True)
    ap.add_argument("--operation-id", default=None)
    ap.add_argument("--actor", required=True)
    ap.add_argument("--reason", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    m = re.fullmatch(r"([1-9][0-9]*)-([1-9][0-9]*)", args.ordinals)
    if not m or int(m.group(1)) > int(m.group(2)):
        sys.exit("--ordinals must be from-to")
    first, last = int(m.group(1)), int(m.group(2))
    with open(args.csv, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    ordinals = [int(r["ordinal"]) for r in rows]
    if ordinals != list(range(1, len(rows) + 1)) or last > len(rows):
        sys.exit("CSV must be ordered 1..N without gaps and contain the whole range")
    guids = [int(r["guid"]) for r in rows if first <= int(r["ordinal"]) <= last]
    if len(set(int(r["guid"]) for r in rows)) != len(rows):
        sys.exit("CSV contains duplicate GUIDs")
    if args.expected_current_version <= 0:
        sys.exit("--expected-current-version must be positive")

    operation_id = args.operation_id or str(uuid.uuid4())
    data = build(guids, args.expected_current_version, last, operation_id,
                 args.actor, args.reason)
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"operation_id={operation_id}")
    print(f"add_count={len(guids)} requested_target_count={last}")
    print(f"request_sha256={hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
