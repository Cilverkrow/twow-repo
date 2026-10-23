"""Quest feasibility catalog (twow-repo#601 R08a): ``python -m dbcheck catalog <generate|lint|check>``.

``catalog/quest-feasibility.toml`` is the only hand-edited input. From it:

* ``generate`` renders ``quest-feasibility.tsv`` (one row per quest, with its reason) and ``quest-feasibility.keys``
  (the two ``AiPlayerbot.QuestFeasibility.*`` lines the run profile carries). No database.
* ``lint`` (CI lint job, no database) fails when the rendered files are stale, when the profile's key lines differ
  from the rendered ones, or when the catalog breaks its own rules (freeze, reasons, 512 ids per list).
* ``check`` runs ``catalog/facts.toml`` against a disposable world database: every ``basis = "rule"`` quest must still
  match its rule and every override quest must exist. Whole-database rule hits outside the catalog go to a candidates
  report that never fails (the lists are frozen; a new id needs an OB-00 approval in the TOML).
"""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

from .binding import Binding
from .errors import ConfigError
from .template import check_readonly, expand, sql_int_list

LISTS = {
    "blocklist": "AiPlayerbot.QuestFeasibility.Blocklist",
    "no_custom_starts": "AiPlayerbot.QuestFeasibility.BlocklistWhileNoCustomStarts",
}
BASES = ("rule", "override")
CLASSES = ("impossible", "needs_group", "config")
MAX_IDS = 512  # core ai::quest_feasibility::ParseQuestIdList keeps at most 512 ids per list
TSV_COLUMNS = ("id", "list", "basis", "rule", "class", "category", "title", "reason", "evidence")
_APPROVED = re.compile(r"^OB-00 \d{4}-\d{2}-\d{2} \S+")


@dataclass(frozen=True)
class Quest:
    entry: int
    list: str
    basis: str
    rule: str
    klass: str
    category: str
    title: str
    reason: str
    evidence: str
    approved: str


@dataclass
class Catalog:
    quests: list[Quest]
    baseline: frozenset[int]

    def ids(self, list_name: str | None = None) -> list[int]:
        return sorted(q.entry for q in self.quests if list_name is None or q.list == list_name)


@dataclass(frozen=True)
class Fact:
    name: str
    title: str
    predicate: str


def _text(path: Path, spec: dict, key: str, entry) -> str:
    v = spec.get(key, "")
    if not isinstance(v, str):
        raise ConfigError(f"{path}: quest {entry}: '{key}' must be a string")
    if any(c in v for c in "\t\r\n"):
        raise ConfigError(f"{path}: quest {entry}: '{key}' must not contain tabs or line breaks")
    return v.strip()


def load_catalog(path: Path, facts: dict[str, Fact] | None = None) -> Catalog:
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError, OSError) as e:
        raise ConfigError(f"{path}: {e}") from e
    meta = data.get("catalog", {})
    baseline = meta.get("frozen_baseline")
    if not isinstance(baseline, list) or not all(isinstance(x, int) and not isinstance(x, bool) for x in baseline):
        raise ConfigError(f"{path}: [catalog].frozen_baseline must be a list of quest ids")
    quests, seen = [], set()
    for spec in data.get("quest", []):
        entry = spec.get("entry")
        if not isinstance(entry, int) or isinstance(entry, bool) or entry <= 0:
            raise ConfigError(f"{path}: quest entry must be a positive integer, got {entry!r}")
        if entry in seen:
            raise ConfigError(f"{path}: quest {entry} is listed twice")
        seen.add(entry)
        q = Quest(
            entry=entry,
            list=_text(path, spec, "list", entry),
            basis=_text(path, spec, "basis", entry),
            rule=_text(path, spec, "rule", entry),
            klass=_text(path, spec, "class", entry),
            category=_text(path, spec, "category", entry),
            title=_text(path, spec, "title", entry),
            reason=_text(path, spec, "reason", entry),
            evidence=_text(path, spec, "evidence", entry),
            approved=_text(path, spec, "approved", entry),
        )
        if q.list not in LISTS:
            raise ConfigError(f"{path}: quest {entry}: list must be one of {sorted(LISTS)}")
        if q.basis not in BASES:
            raise ConfigError(f"{path}: quest {entry}: basis must be one of {BASES}")
        if q.klass not in CLASSES:
            raise ConfigError(f"{path}: quest {entry}: class must be one of {CLASSES}")
        if q.basis == "rule" and not q.rule:
            raise ConfigError(f"{path}: quest {entry}: basis 'rule' needs a 'rule'")
        if q.basis == "override" and q.rule:
            raise ConfigError(f"{path}: quest {entry}: an override names no 'rule'")
        if facts is not None and q.rule and q.rule not in facts:
            raise ConfigError(f"{path}: quest {entry}: unknown rule '{q.rule}' (catalog/facts.toml)")
        for key in ("category", "title", "reason", "evidence"):
            if not getattr(q, key):
                raise ConfigError(f"{path}: quest {entry}: '{key}' is required")
        if entry not in baseline and not _APPROVED.match(q.approved):
            raise ConfigError(
                f"{path}: quest {entry} is not in the frozen baseline (OB-00 2026-10-19); it needs "
                "approved = \"OB-00 YYYY-MM-DD <link>\""
            )
        quests.append(q)
    cat = Catalog(quests, frozenset(baseline))
    for name in LISTS:
        if len(cat.ids(name)) > MAX_IDS:
            raise ConfigError(f"{path}: list {name} has {len(cat.ids(name))} ids; the core reads at most {MAX_IDS}")
    return cat


def load_facts(path: Path) -> dict[str, Fact]:
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError, OSError) as e:
        raise ConfigError(f"{path}: {e}") from e
    out = {}
    for name, spec in data.get("fact", {}).items():
        if not spec.get("predicate") or not spec.get("title"):
            raise ConfigError(f"{path}: fact {name}: 'predicate' and 'title' are required")
        out[name] = Fact(name, str(spec["title"]), str(spec["predicate"]))
    if not out:
        raise ConfigError(f"{path}: no [fact.*] rules")
    return out


def render_tsv(cat: Catalog) -> str:
    """One row per quest, sorted by list then id; no timestamp, so equal input gives equal bytes."""
    lines = ["\t".join(TSV_COLUMNS)]
    for q in sorted(cat.quests, key=lambda q: (q.list, q.entry)):
        lines.append("\t".join([str(q.entry), q.list, q.basis, q.rule, q.klass, q.category, q.title, q.reason, q.evidence]))
    return "\n".join(lines) + "\n"


def render_keys(cat: Catalog) -> str:
    return "".join(f"{key} = {','.join(str(i) for i in cat.ids(name))}\n" for name, key in LISTS.items())


def profile_key_lines(text: str) -> dict[str, str]:
    """The ``AiPlayerbot.QuestFeasibility.*`` list lines of a profile overlay, by key (a key set twice is an error)."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        for key in LISTS.values():
            if re.match(rf"^\s*{re.escape(key)}\s*=", line):
                if key in out:
                    raise ConfigError(f"profile sets {key} twice")
                out[key] = line.strip()
    return out


def lint(cat: Catalog, tsv: Path, keys: Path, profile: Path | None) -> list[str]:
    problems = []
    want_tsv, want_keys = render_tsv(cat), render_keys(cat)
    for path, want in ((tsv, want_tsv), (keys, want_keys)):
        have = path.read_text(encoding="utf-8") if path.exists() else None
        if have != want:
            problems.append(f"{path.name} is stale: run `python3 -m dbcheck catalog generate` and commit it")
    if profile is not None:
        have = profile_key_lines(profile.read_text(encoding="utf-8"))
        for line in want_keys.splitlines():
            key = line.split(" = ", 1)[0]
            if have.get(key) != line:
                problems.append(f"{profile}: the {key} line differs from catalog/quest-feasibility.keys")
    return problems


def fact_sql(fact: Fact, binding: Binding, macros: dict[str, str], ids: list[int] | None) -> str:
    """The rule as one read-only SELECT: the catalog ids that match (ids given), or every non-retired quest that does."""
    scope = f"q.{{quest.entry}} IN ({sql_int_list(ids)})" if ids is not None else "{%quest_not_ignored}"
    sql = f"SELECT q.{{quest.entry}} AS quest FROM {{quest}} q WHERE {scope} AND ({fact.predicate})"
    sql = expand(sql, binding, macros, {})
    check_readonly(sql, f"fact {fact.name}")
    return sql


@dataclass
class CheckResult:
    problems: list[str]
    rows: list[tuple]          # id, list, basis, rule, matching rules, status
    candidates: list[tuple]    # rule, quest (whole-database hits outside the catalog)

    def failing(self) -> bool:
        return bool(self.problems)


def check(runner, binding: Binding, macros: dict[str, str], cat: Catalog, facts: dict[str, Fact],
          candidates: bool = True) -> CheckResult:
    """Each fact once over the catalog ids (and once over the whole database for the candidates report)."""
    ids = cat.ids()
    matches: dict[int, list[str]] = {i: [] for i in ids}
    for name in sorted(facts):
        _, rows = runner.query(fact_sql(facts[name], binding, macros, ids))
        for (quest,) in rows:
            if int(quest) in matches:
                matches[int(quest)].append(name)
    _, rows = runner.query(expand(
        f"SELECT q.{{quest.entry}} AS quest FROM {{quest}} q WHERE q.{{quest.entry}} IN ({sql_int_list(ids)})",
        binding, macros, {}))
    present = {int(r[0]) for r in rows}
    problems, out = [], []
    for q in sorted(cat.quests, key=lambda q: (q.list, q.entry)):
        got = matches[q.entry]
        if q.entry not in present:
            status = "missing"
            problems.append(f"quest {q.entry} ({q.title}) is not in the quest table")
        elif q.basis == "rule" and q.rule not in got:
            status = "rule_gone"
            problems.append(f"quest {q.entry} ({q.title}) no longer matches {q.rule}: the reason is gone, "
                            "remove it from the catalog (or make it an override with a new reason)")
        else:
            status = "ok"
        out.append((q.entry, q.list, q.basis, q.rule, ",".join(got), status))
    cands = []
    if candidates:
        known = set(ids)
        for name in sorted(facts):
            _, rows = runner.query(fact_sql(facts[name], binding, macros, None))
            cands.extend((name, int(r[0])) for r in rows if int(r[0]) not in known)
    return CheckResult(problems, out, sorted(cands))


def write_check(res: CheckResult, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    lines = ["id\tlist\tbasis\trule\tmatches\tstatus"] + ["\t".join(str(c) for c in r) for r in res.rows]
    (out / "catalog-check.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    lines = ["rule\tquest"] + [f"{r}\t{q}" for r, q in res.candidates]
    (out / "catalog-candidates.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    counts: dict[str, int] = {}
    for r, _ in res.candidates:
        counts[r] = counts.get(r, 0) + 1
    summary = [f"problems: {len(res.problems)}"] + [f"  {p}" for p in res.problems]
    summary += ["candidates (report only, frozen lists; a new id needs an OB-00 approval):"]
    summary += [f"  {r}: {n}" for r, n in sorted(counts.items())]
    (out / "catalog-summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8", newline="\n")
