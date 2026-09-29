"""Command line: ``python -m dbcheck <check|list-rules|run>``."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from . import __version__, engine, report
from .binding import load_binding
from .errors import ConfigError, DbCheckError
from .expected import load_all
from .rules import load_rules
from .runner import MysqlRunner, SqliteRunner
from .template import check_readonly, expand

ROOT = Path(__file__).resolve().parent.parent


def _common(p):
    p.add_argument("--binding", type=Path, default=ROOT / "bindings" / "tw-world.toml")
    p.add_argument("--rules", type=Path, default=ROOT / "rules")
    p.add_argument("--expected", type=Path, action="append", default=None,
                   help="expected file or directory (repeatable; default: expected/)")


def _validate(binding, rules, macros, expected):
    """Expand every rule with dummy parameters: catches typos before a run."""
    dummy = {
        "entry": "1", "giver": "1", "ender": "1", "names": "'x'", "names_table": "SELECT 'x' AS expected",
        "instance_entries": "1", "allow_elsewhere": "NULL", "spawn_optional": "0", "instance_maps": "1", "scripted_starts": "-1", "scripted_ends": "-1", "summoned_entries": "-1", "credited_entries": "-1", "dead_entries": "-1", "rank": "3",
    }
    for r in rules.values():
        sql = expand(r.sql, binding, macros, dummy)
        check_readonly(sql, f"rule {r.name}")
    return len(rules)


def cmd_check(a):
    binding = load_binding(a.binding)
    rules, macros = load_rules(a.rules)
    expected = load_all(a.expected or [ROOT / "expected"])
    n = _validate(binding, rules, macros, expected)
    print(f"ok: binding {binding.id}, {n} rules, {len(expected)} expected list(s)")
    return 0


def cmd_list(a):
    rules, _ = load_rules(a.rules)
    for name in sorted(rules):
        r = rules[name]
        print(f"{name}\t{r.scope}\t{r.severity}\t{r.title}")
    return 0


def cmd_run(a):
    binding = load_binding(a.binding)
    rules, macros = load_rules(a.rules)
    expected = load_all(a.expected or [ROOT / "expected"])
    _validate(binding, rules, macros, expected)
    cmd = a.mysql_cmd or os.environ.get("DBCHECK_MYSQL")
    if a.sqlite:
        runner = SqliteRunner(a.sqlite)
    elif cmd:
        if not a.disposable:
            raise ConfigError(
                "refusing to run against a database without --disposable: the rules join large tables and "
                "must never run against the live database. Pass --disposable to confirm the target is a copy."
            )
        runner = MysqlRunner(cmd, statement_seconds=a.statement_seconds)
        extra = runner.check_grants()
        if extra and not a.skip_grant_check:
            raise ConfigError(
                "the database user holds more than SELECT/SHOW VIEW (" + ", ".join(extra) + "); "
                "use a read-only user, or --skip-grant-check if you accept that"
            )
    else:
        raise ConfigError("no database: pass --mysql-cmd (or DBCHECK_MYSQL) or --sqlite")
    only = set(a.only.split(",")) if a.only else None
    if only and not only <= set(rules):
        raise ConfigError("unknown rule(s): " + ", ".join(sorted(only - set(rules))))
    run = engine.run(runner, binding, rules, macros, expected, only, progress=lambda m: print(m, file=sys.stderr, flush=True))
    text, data = report.build(run, expected, a.max_rows)
    digest = report.sha256_of(text)
    print(text, end="")
    print(f"report sha256: {digest}")
    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        (a.out / "report.md").write_text(text, encoding="utf-8", newline="\n")
        (a.out / "report.json").write_text(report.dump_json(data), encoding="utf-8", newline="\n")
        (a.out / "SHA256SUMS").write_text(
            f"{digest}  report.md\n{report.sha256_of(report.dump_json(data))}  report.json\n", encoding="utf-8", newline="\n"
        )
    return 1 if run.failing() else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="dbcheck", description="Expected-vs-actual checks of the world database.")
    ap.add_argument("--version", action="version", version=f"dbcheck {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check", help="validate bindings, rules and expected lists (no database)")
    _common(p)
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("list-rules", help="list the rules")
    p.add_argument("--rules", type=Path, default=ROOT / "rules")
    p.set_defaults(fn=cmd_list)
    p = sub.add_parser("run", help="run the rules against a database (read-only SELECTs)")
    _common(p)
    p.add_argument("--mysql-cmd", help="client command reading SQL from stdin (or env DBCHECK_MYSQL)")
    p.add_argument("--sqlite", help="SQLite file (test fixtures only)")
    p.add_argument("--disposable", action="store_true", help="required with --mysql-cmd: confirms the target is a disposable copy, not live")
    p.add_argument("--skip-grant-check", action="store_true", help="do not refuse a database user that can write")
    p.add_argument("--statement-seconds", type=int, default=120, help="MariaDB max_statement_time per query; 0 = off (default 120)")
    p.add_argument("--only", help="comma-separated rule names")
    p.add_argument("--max-rows", type=int, default=50, help="rows per finding in report.md (JSON has all)")
    p.add_argument("--out", type=Path, help="write report.md, report.json, SHA256SUMS here")
    p.set_defaults(fn=cmd_run)
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except DbCheckError as e:
        print(f"dbcheck: error: {e}", file=sys.stderr)
        return 2
