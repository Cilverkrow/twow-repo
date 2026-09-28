"""Consistency check: client DBC content against server SQL content.

Rules are declarative (``consistency/*.toml``), so a new table pairing is a
config change, not code::

    [[rule]]
    id = "areatrigger-position"
    kind = "fields_equal"          # or "keys_in_dbc"
    source = "areatrigger_template"
    dbc = "AreaTrigger"
    scope = "all"                  # all keys in both | "changed": keys our deltas touch
    skip_sql_value = "-1"          # optional: SQL value meaning "keep the DBC value"
    why = "..."

    [[rule.pair]]
    sql = "x"
    dbc = "Pos[0]"
    tolerance = 0.5                # floats only

    [[rule.accept]]                # known, reviewed differences
    key = "5340"
    reason = "#408: server row has map 0, entrance is on map 532"

``keys_in_dbc`` requires every server key to exist in the client DBC (a
server-only map makes the client hang, #408). ``fields_equal`` compares
paired columns. ``refs_in_sql`` requires the listed DBC columns (for
example ``Talent.SpellRank[0..8]``) to reference rows that exist on the
server (``columns = [...]``; 0 means "none" and is skipped). Any finding that is not accepted fails the build; an accept
entry that matches no finding is reported as stale.
"""

from __future__ import annotations

import csv
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .errors import ConsistencyError
from .sqlsrc import SqlData
from .delta import parse_int


@dataclass
class Finding:
    rule: str
    key: str
    message: str
    accepted: str = ""  # reason, when accepted


@dataclass
class Rule:
    id: str
    kind: str
    source: str
    dbc: str
    scope: str = "all"
    pairs: list[dict] = field(default_factory=list)
    accept: dict[str, str] = field(default_factory=dict)
    skip_sql_value: str | None = None
    why: str = ""
    columns: list[str] = field(default_factory=list)


def load_rules(directory: Path) -> list[Rule]:
    rules: list[Rule] = []
    ids: set[str] = set()
    for p in sorted(directory.glob("*.toml")):
        data = tomllib.loads(p.read_text(encoding="utf-8"))
        for r in data.get("rule", []):
            rid = str(r.get("id", ""))
            if not rid or rid in ids:
                raise ConsistencyError(f"{p}: rule id {rid!r} missing or duplicate")
            ids.add(rid)
            kind = r.get("kind")
            if kind not in ("keys_in_dbc", "fields_equal", "refs_in_sql"):
                raise ConsistencyError(f"{p}: rule {rid}: unknown kind {kind!r}")
            scope = r.get("scope", "all")
            if scope not in ("all", "changed"):
                raise ConsistencyError(f"{p}: rule {rid}: scope must be all or changed")
            pairs = list(r.get("pair", []))
            if kind == "fields_equal" and not pairs:
                raise ConsistencyError(f"{p}: rule {rid}: fields_equal needs [[rule.pair]]")
            columns = [str(c) for c in r.get("columns", [])]
            if kind == "refs_in_sql" and not columns:
                raise ConsistencyError(f"{p}: rule {rid}: refs_in_sql needs columns = [...]")
            accept = {str(a["key"]): str(a.get("reason", "")) for a in r.get("accept", [])}
            if any(not reason for reason in accept.values()):
                raise ConsistencyError(f"{p}: rule {rid}: every accept needs a reason")
            skip = r.get("skip_sql_value")
            rules.append(Rule(id=rid, kind=kind, source=str(r["source"]), dbc=str(r["dbc"]),
                              scope=scope, pairs=pairs, accept=accept,
                              skip_sql_value=None if skip is None else str(skip),
                              columns=columns,
                              why=str(r.get("why", ""))))
    return rules


def dbcs_needed(rules: list[Rule]) -> list[str]:
    return sorted({r.dbc for r in rules})


def sources_needed(rules: list[Rule]) -> list[str]:
    return sorted({r.source for r in rules})


def _norm_int(v) -> int:
    return int(v) & 0xFFFFFFFF


def _equal(dbc_value, sql_value: str, kind: str, tolerance: float) -> bool:
    if kind == "float":
        return abs(float(dbc_value) - float(sql_value)) <= tolerance
    if kind == "int":
        return _norm_int(dbc_value) == _norm_int(parse_int(sql_value))
    return str(dbc_value) == sql_value


def run(rules: list[Rule], tables: dict, sql: SqlData, touched: dict) -> list[Finding]:
    """``tables``: dbc name -> Table (patched where changed);
    ``touched``: dbc name -> Touched for the DBCs our deltas changed."""
    findings: list[Finding] = []
    for rule in rules:
        table = tables[rule.dbc]
        b = table.binding
        if len(b.key) != 1 and rule.kind != "refs_in_sql":
            raise ConsistencyError(f"rule {rule.id}: {rule.dbc} has a composite key")
        _, rows = sql.table(rule.source)
        local: list[Finding] = []
        if rule.kind == "refs_in_sql":
            t = touched.get(rule.dbc)
            keys = sorted(t.keys()) if rule.scope == "changed" else sorted(table.keys())
            if rule.scope == "changed" and not t:
                keys = []
            for k in keys:
                for c in rule.columns:
                    v = table.get(k, c)
                    if v and (_norm_int(v) not in rows and int(v) not in rows):
                        local.append(Finding(rule.id, ":".join(map(str, k)),
                                             f"{rule.dbc}.{c}={v} has no server {rule.source} row"))
        elif rule.kind == "keys_in_dbc":
            for k in sorted(rows):
                if not table.has_key((k,)):
                    local.append(Finding(rule.id, str(k),
                                         f"server {rule.source} row {k} has no {rule.dbc}.dbc row"))
        else:
            if rule.scope == "changed":
                t = touched.get(rule.dbc)
                keys = sorted(k[0] for k in t.keys()) if t else []
            else:
                keys = sorted(k for k in rows if table.has_key((k,)))
            for k in keys:
                srow = rows.get(k)
                if srow is None:
                    local.append(Finding(rule.id, str(k),
                                         f"{rule.dbc}.dbc row {k} has no server {rule.source} row"))
                    continue
                for pair in rule.pairs:
                    col = b.columns[b.index(pair["dbc"])]
                    sval = srow.get(pair["sql"])
                    if pair["sql"] not in srow:
                        raise ConsistencyError(
                            f"rule {rule.id}: column {pair['sql']!r} not in the {rule.source} export")
                    if sval is None or (rule.skip_sql_value is not None and sval == rule.skip_sql_value):
                        continue
                    dval = table.get((k,), pair["dbc"])
                    tol = float(pair.get("tolerance", 0.0))
                    if not _equal(dval, sval, col.kind, tol):
                        local.append(Finding(rule.id, str(k),
                                             f"{rule.dbc}.{pair['dbc']}={dval!r} but "
                                             f"{rule.source}.{pair['sql']}={sval!r}"))
        matched = set()
        for f in local:
            if f.key in rule.accept:
                f.accepted = rule.accept[f.key]
                matched.add(f.key)
        for k in sorted(set(rule.accept) - matched):
            local.append(Finding(rule.id, k, "stale accept entry: no such difference any more",
                                 accepted="stale"))
        findings += local
    return findings


def blocking(findings: list[Finding]) -> list[Finding]:
    return [f for f in findings if not f.accepted]


def write_report(findings: list[Finding], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["rule", "key", "status", "message"])
        for x in findings:
            status = "BLOCKING" if not x.accepted else (
                "stale-accept" if x.accepted == "stale" else f"accepted: {x.accepted}")
            w.writerow([x.rule, x.key, status, x.message])
