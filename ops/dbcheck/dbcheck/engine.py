"""Run rules against a database and collect findings."""

from __future__ import annotations

from dataclasses import dataclass, field

from .binding import Binding, check_schema
from .expected import Expected
from .rules import Rule
from .runner import Runner
from .template import check_readonly, expand, sql_int_list, sql_string_list, sql_string_table


@dataclass
class Result:
    rule: Rule
    subject: str  # "" for global rules, else "<instance>: <boss or quest>"
    columns: list[str]
    rows: list[tuple]
    skipped: str = ""


@dataclass
class Run:
    binding: Binding
    fingerprint: str
    results: list[Result] = field(default_factory=list)

    def failing(self) -> list[Result]:
        return [r for r in self.results if r.rows and r.rule.severity in ("error", "warn")]


def _sorted_rows(rows):
    return sorted(rows, key=lambda r: tuple("" if v is None else v for v in r))


def _boss_params(exp: Expected, boss) -> dict[str, str]:
    return {
        "entry": str(boss.entry),
        "names": sql_string_list(boss.loot) if boss.loot else "",
        "names_table": sql_string_table(boss.loot) if boss.loot else "",
        "instance_entries": sql_int_list([b.entry for b in exp.bosses]),
        "allow_elsewhere": sql_string_list(exp.allow_elsewhere),
        "spawn_optional": "1" if boss.spawn_optional else "0",
    }


def _quest_params(exp: Expected, q) -> dict[str, str]:
    return {
        "entry": str(q.entry),
        "giver": "" if q.giver is None else str(q.giver),
        "ender": "" if q.ender is None else str(q.ender),
    }


def _execute(runner: Runner, rule: Rule, sql: str, subject: str) -> Result:
    check_readonly(sql, f"rule {rule.name}")
    cols, rows = runner.query(sql)
    return Result(rule, subject, cols, _sorted_rows(rows))


def run(
    runner: Runner,
    binding: Binding,
    rules: dict[str, Rule],
    macros: dict[str, str],
    expected: list[Expected],
    only: set[str] | None = None,
) -> Run:
    fp = check_schema(binding, runner.schema())
    out = Run(binding, fp)
    for name in sorted(rules):
        rule = rules[name]
        if only and name not in only:
            continue
        if rule.scope == "global":
            sql = expand(rule.sql, binding, macros, {})
            out.results.append(_execute(runner, rule, sql, ""))
            continue
        for exp in expected:
            items = exp.bosses if rule.scope == "boss" else exp.quests
            for it in items:
                params = _boss_params(exp, it) if rule.scope == "boss" else _quest_params(exp, it)
                label = getattr(it, "name", None) or getattr(it, "title", "")
                subject = f"{exp.name}: {label} ({it.entry})"
                empty = [p for p in rule.requires if not params.get(p)]
                if empty:
                    out.results.append(Result(rule, subject, [], [], skipped=f"no {', '.join(empty)} in the expected list"))
                    continue
                sql = expand(rule.sql, binding, macros, params)
                out.results.append(_execute(runner, rule, sql, subject))
    return out
