"""Command line: python -m clientpatch <command> ...  (run from ops/clientpatch/)."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import __version__, consistency
from .base import fingerprint_toml
from .binding import load_bindings
from .build import build, build_testpatch, extract_base, load_config, roundtrip
from .delta import changed_dbcs, list_files, read_ops
from .diff import dbcdiff, write_review
from .errors import ClientPatchError
from .sqlsrc import export, load_sources
from .wdbc import Table

DEFAULT_CONFIG = Path(__file__).resolve().parent.parent / "clientpatch.toml"
DEFAULT_BUILD = "1.12.1.5875"


def _bindings(cfg, build_id):
    return load_bindings(cfg.dir("bindings") / build_id)


def cmd_build(a, cfg):
    info = build(cfg, Path(a.base), Path(a.sql), a.version, a.label, Path(a.out), a.mpqcli)
    print(json.dumps({k: info[k] for k in ("version", "base", "files")}, indent=2))


def cmd_testpatch(a, cfg):
    info = build_testpatch(cfg, a.version, a.label, Path(a.out), a.mpqcli)
    print(json.dumps({k: info[k] for k in ("version", "kind", "files")}, indent=2))


def cmd_extract_base(a, cfg):
    src = extract_base(cfg, Path(a.client), Path(a.out), a.mpqcli)
    print(f"{len(src)} DBC(s) -> {a.out} (see extract-report.txt)")


def cmd_fingerprint(a, cfg):
    text = fingerprint_toml(Path(a.base), a.id, a.build, a.client, a.registered)
    if a.write:
        p = cfg.dir("bases") / f"{a.id}.toml"
        if p.exists():
            raise ClientPatchError(f"{p} exists; a registered base is never overwritten")
        p.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {p}")
    else:
        sys.stdout.write(text)


def cmd_roundtrip(a, cfg):
    problems = roundtrip(_bindings(cfg, a.build), Path(a.base))
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        raise ClientPatchError(f"{len(problems)} DBC(s) failed the round trip")
    print("round trip: every bound DBC is byte-identical")


def cmd_dbcdiff(a, cfg):
    b = _bindings(cfg, a.build)[a.dbc]
    diffs = dbcdiff(Table.read(Path(a.old), b), Table.read(Path(a.new), b))
    write_review(diffs, Path(a.out))
    print(f"{len(diffs)} difference(s) -> {a.out}")


def cmd_columns(a, cfg):
    b = _bindings(cfg, a.build)[a.dbc]
    for i, c in enumerate(b.columns):
        mark = " (key)" if c.name in b.key else ""
        print(f"{i:3} {c.name:40} {c.type}{mark}")


def cmd_export_sql(a, cfg):
    cmd = a.mysql_cmd or os.environ.get("CLIENTPATCH_MYSQL", "")
    for p in export(load_sources(cfg.dir("sql_sources")), Path(a.out), cmd):
        print(f"wrote {p}")


def cmd_check(a, cfg):
    """Validate everything that needs no client files: bindings, rules,
    SQL sources, delta files (syntax and columns). Used by CI."""
    bindings = _bindings(cfg, a.build)
    rules = consistency.load_rules(cfg.dir("consistency"))
    sources = load_sources(cfg.dir("sql_sources"))
    for r in rules:
        if r.dbc not in bindings:
            raise ClientPatchError(f"rule {r.id}: no binding for {r.dbc}")
        if r.source not in sources:
            raise ClientPatchError(f"rule {r.id}: undeclared SQL source {r.source}")
        for p in r.pairs:
            bindings[r.dbc].index(p["dbc"])
        for c in r.columns:
            bindings[r.dbc].index(c)
    ops = 0
    for dbc in changed_dbcs(cfg.dir("changes")):
        if dbc not in bindings:
            raise ClientPatchError(f"changes/{dbc}: no binding for {dbc}")
        for f in list_files(cfg.dir("changes"), dbc):
            for line, row in read_ops(f):
                if row["op"].strip() == "set":
                    bindings[dbc].index(row["field"].strip())
                ops += 1
    print(f"ok: {len(bindings)} binding(s), {len(rules)} rule(s), "
          f"{len(sources)} SQL source(s), {ops} delta op(s)")


def cmd_catalog(a, cfg):
    info = json.loads(Path(a.build_info).read_text(encoding="utf-8"))
    name = cfg.patch["release_name"].format(version=info["version"])
    f = info["files"][name]
    entry = {
        "id": a.id, "name": a.name,
        "description": f"{a.name} v{info['version']}: {info.get('label', '')}".strip(),
        "url": a.url_base.rstrip("/") + "/" + name,
        "dest": "Data/" + cfg.patch["name"],
        "version": str(info["version"]), "sha1": f["sha1"], "size": f["size"],
        "essential": True,
    }
    print(json.dumps([entry], indent=2))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="clientpatch", description=__doc__)
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    ap.add_argument("--version-info", action="version", version=f"clientpatch {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("build", help="deltas -> DBC -> MPQ (full pipeline)")
    p.add_argument("--base", required=True, help="directory with the pristine client DBCs")
    p.add_argument("--sql", required=True, help="directory with the export-sql TSV files")
    p.add_argument("--version", required=True, type=int)
    p.add_argument("--label", default="")
    p.add_argument("--out", required=True)
    p.add_argument("--mpqcli")
    p.set_defaults(fn=cmd_build)

    p = sub.add_parser("testpatch", help="archive with only the version file (no client data)")
    p.add_argument("--version", required=True, type=int)
    p.add_argument("--label", default="transport test")
    p.add_argument("--out", required=True)
    p.add_argument("--mpqcli")
    p.set_defaults(fn=cmd_testpatch)

    p = sub.add_parser("extract-base", help="extract the pristine DBCs from the client archives")
    p.add_argument("--client", required=True, help="client folder (or its Data folder)")
    p.add_argument("--out", required=True, help="base directory to create (outside the repository)")
    p.add_argument("--mpqcli")
    p.set_defaults(fn=cmd_extract_base)

    p = sub.add_parser("fingerprint", help="register a pristine client base (hashes only)")
    p.add_argument("--base", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--build", default=DEFAULT_BUILD)
    p.add_argument("--client", required=True, help='e.g. "Turtle WoW 1.18.1 (build 7272), English"')
    p.add_argument("--registered", default="", help="date and who, e.g. 2026-10-01, OB-15")
    p.add_argument("--write", action="store_true", help="write bases/<id>.toml")
    p.set_defaults(fn=cmd_fingerprint)

    p = sub.add_parser("roundtrip", help="byte-identical read/write check of every bound DBC")
    p.add_argument("--base", required=True)
    p.add_argument("--build", default=DEFAULT_BUILD)
    p.set_defaults(fn=cmd_roundtrip)

    p = sub.add_parser("dbcdiff", help="field-level diff of two versions of one DBC")
    p.add_argument("dbc")
    p.add_argument("old")
    p.add_argument("new")
    p.add_argument("--build", default=DEFAULT_BUILD)
    p.add_argument("--out", default="review.csv")
    p.set_defaults(fn=cmd_dbcdiff)

    p = sub.add_parser("columns", help="list the columns of a DBC binding")
    p.add_argument("dbc")
    p.add_argument("--build", default=DEFAULT_BUILD)
    p.set_defaults(fn=cmd_columns)

    p = sub.add_parser("export-sql", help="read-only export of the declared server SQL sources")
    p.add_argument("--out", required=True)
    p.add_argument("--mysql-cmd", help="client command, default $CLIENTPATCH_MYSQL")
    p.set_defaults(fn=cmd_export_sql)

    p = sub.add_parser("check", help="validate bindings, rules, sources and deltas (no client needed)")
    p.add_argument("--build", default=DEFAULT_BUILD)
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("catalog", help="Nostalgia assets.json entry for a built release")
    p.add_argument("--build-info", required=True)
    p.add_argument("--url-base", required=True, help="https://<patch-host>/files")
    p.add_argument("--id", default="twow-patch")
    p.add_argument("--name", default="TWOW client patch")
    p.set_defaults(fn=cmd_catalog)

    a = ap.parse_args(argv)
    try:
        a.fn(a, load_config(Path(a.config)))
    except ClientPatchError as e:
        print(f"clientpatch: error: {e}", file=sys.stderr)
        return 2
    except KeyError as e:
        print(f"clientpatch: error: unknown name {e}", file=sys.stderr)
        return 2
    return 0
