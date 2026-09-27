#!/usr/bin/env python3
"""Build the canonical REPLACE admin request (twow-repo#366 wave 1, race balance).

A REPLACE keeps the roster size and every ordinal; each listed old GUID is swapped for its
new GUID at the same position (core PersistentActiveRoster.cpp BuildAfter). The replaced
characters are not touched and simply stay offline, so a ROLLBACK to the previous version
brings them back with their progress.

Same canonical serialization as the core's SerializeAdminRequest(): LF, UTF-8 without BOM,
unpadded base64url, empty add/remove lists, rollback_version_id=null, and the replace rows
sorted by old GUID ascending and numbered 1..n (NON_CANONICAL_REPLACE_LIST otherwise):

    replace\\t<index 10 digits>\\t<old guid 10 digits>\\t<new guid 10 digits>

    python3 make_replace_request.py --replace replace.tsv --expected-current-version 4 \
        --target-count 154 --actor <who> --reason <why> --out replace-request.txt

replace.tsv holds "ordinal<TAB>old_guid<TAB>new_guid" per row, as select_roster_v5.py
--replace-out writes it; the ordinal is only checked, the request itself has no ordinals.
"""
import argparse
import hashlib
import sys
import unicodedata
import uuid

from make_expand_request import UUID_V4, b64url, ten


def build(pairs, expected_current, target_count, operation_id, actor, reason):
    if not UUID_V4.match(operation_id):
        raise ValueError("operation id must be a canonical lowercase UUIDv4")
    if not actor:
        raise ValueError("actor must not be empty")
    for label, text in (("actor", actor), ("reason", reason)):
        if unicodedata.normalize("NFC", text) != text:
            raise ValueError(f"{label} must be NFC")
    if expected_current <= 0 or target_count <= 0 or not pairs:
        raise ValueError("need a positive current version, a positive target count and at least one pair")
    olds = [o for o, _ in pairs]
    news = [n for _, n in pairs]
    if len(set(olds)) != len(olds) or len(set(news)) != len(news) or set(olds) & set(news):
        raise ValueError("old and new GUIDs must be unique and disjoint")
    lines = [
        "ssc-rndbot-admin-request-v1",
        "schema_version=1",
        f"operation_id={operation_id}",
        "operation_type=REPLACE",
        f"expected_current_version_id={expected_current}",
        f"actor_utf8_b64url={b64url(actor)}",
        f"reason_utf8_b64url={b64url(reason)}",
        f"requested_target_count={target_count}",
        "add_count=0",
        "remove_count=0",
        f"replace_count={len(pairs)}",
    ]
    for i, (old, new) in enumerate(sorted(pairs), start=1):
        lines.append(f"replace\t{ten(i)}\t{ten(old)}\t{ten(new)}")
    lines.append("rollback_version_id=null")
    return ("\n".join(lines) + "\n").encode("utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--replace", required=True, help="TSV ordinal old_guid new_guid")
    ap.add_argument("--expected-current-version", type=int, required=True)
    ap.add_argument("--target-count", type=int, required=True, help="roster size (unchanged by REPLACE)")
    ap.add_argument("--operation-id", default=None)
    ap.add_argument("--actor", required=True)
    ap.add_argument("--reason", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    pairs = []
    with open(args.replace, encoding="utf-8") as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                ordinal, old, new = (int(x) for x in line.rstrip("\n").split("\t"))
                if not 0 < ordinal <= args.target_count:
                    sys.exit(f"ordinal {ordinal} outside 1..{args.target_count}")
                pairs.append((old, new))
    operation_id = args.operation_id or str(uuid.uuid4())
    try:
        data = build(pairs, args.expected_current_version, args.target_count, operation_id, args.actor, args.reason)
    except ValueError as e:
        sys.exit(str(e))
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"operation_id={operation_id}")
    print(f"replace_count={len(pairs)} requested_target_count={args.target_count}")
    print(f"request_sha256={hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
