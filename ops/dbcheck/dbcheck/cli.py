"""Command line: ``python -m dbcheck <check|list-rules|run>``."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from . import __version__, catalog, engine, report
from .binding import check_schema
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


CATALOG = ROOT / "catalog"


def _catalog_paths(a):
    facts = catalog.load_facts(a.catalog_dir / "facts.toml")
    cat = catalog.load_catalog(a.catalog_dir / "quest-feasibility.toml", facts)
    return facts, cat


def _runner(a):
    """The same database guards as `run`: --disposable, read-only grants, statement time limit."""
    cmd = a.mysql_cmd or os.environ.get("DBCHECK_MYSQL")
    if a.sqlite:
        return SqliteRunner(a.sqlite)
    if not cmd:
        raise ConfigError("no database: pass --mysql-cmd (or DBCHECK_MYSQL) or --sqlite")
    if not a.disposable:
        raise ConfigError("refusing to run against a database without --disposable (never the live database)")
    runner = MysqlRunner(cmd, statement_seconds=a.statement_seconds)
    extra = runner.check_grants()
    if extra and not a.skip_grant_check:
        raise ConfigError("the database user holds more than SELECT/SHOW VIEW (" + ", ".join(extra) + "); use a read-only user")
    return runner


def cmd_catalog(a):
    facts, cat = _catalog_paths(a)
    tsv, keys = a.catalog_dir / "quest-feasibility.tsv", a.catalog_dir / "quest-feasibility.keys"
    if a.action == "generate":
        tsv.write_text(catalog.render_tsv(cat), encoding="utf-8", newline="\n")
        keys.write_text(catalog.render_keys(cat), encoding="utf-8", newline="\n")
        print(f"wrote {tsv.name} ({len(cat.quests)} quests) and {keys.name}")
        return 0
    if a.action == "lint":
        binding = load_binding(a.binding)
        _, macros = load_rules(a.rules)
        for f in facts.values():
            catalog.fact_sql(f, binding, macros, cat.ids())   # every rule expands to one read-only SELECT
        problems = catalog.lint(cat, tsv, keys, a.profile)
        for p in problems:
            print(f"catalog: {p}", file=sys.stderr)
        rules = sum(1 for q in cat.quests if q.basis == "rule")
        print(f"catalog: {len(cat.quests)} quests ({rules} rule, {len(cat.quests) - rules} override), "
              f"{len(problems)} problem(s)")
        return 1 if problems else 0
    binding = load_binding(a.binding)
    _, macros = load_rules(a.rules)
    runner = _runner(a)
    check_schema(binding, runner.schema())
    res = catalog.check(runner, binding, macros, cat, facts, candidates=not a.no_candidates)
    if a.out:
        catalog.write_check(res, a.out)
    for p in res.problems:
        print(f"catalog: {p}", file=sys.stderr)
    print(f"catalog check: {len(res.rows)} quests, {len(res.problems)} problem(s), {len(res.candidates)} candidate hit(s) (report only)")
    return 1 if res.failing() else 0


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
    p = sub.add_parser("catalog", help="quest feasibility catalog: generate | lint | check (twow-repo#601 R08a)")
    p.add_argument("action", choices=("generate", "lint", "check"))
    _common(p)
    p.add_argument("--catalog-dir", type=Path, default=CATALOG)
    p.add_argument("--profile", type=Path, help="lint: profile overlay whose QuestFeasibility lines must equal the .keys")
    p.add_argument("--mysql-cmd", help="check: client command reading SQL from stdin (or env DBCHECK_MYSQL)")
    p.add_argument("--sqlite", help="check: SQLite file (test fixtures only)")
    p.add_argument("--disposable", action="store_true", help="check: required with --mysql-cmd (a disposable copy, not live)")
    p.add_argument("--skip-grant-check", action="store_true")
    p.add_argument("--statement-seconds", type=int, default=120)
    p.add_argument("--no-candidates", action="store_true", help="check: skip the whole-database candidates report")
    p.add_argument("--out", type=Path, help="check: write catalog-check.tsv, catalog-candidates.tsv, catalog-summary.txt")
    p.set_defaults(fn=cmd_catalog)
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except DbCheckError as e:
        print(f"dbcheck: error: {e}", file=sys.stderr)
        return 2
