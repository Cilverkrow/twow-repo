"""Rule files: ``rules/*.toml``.

::

    [macro]
    name = "SELECT ..."             # reusable SQL, used as {%name}

    [rule.quest_no_giver]
    scope = "global"                # global | boss | quest
    severity = "error"              # error | warn | info
    title = "Quest without a starter"
    description = "..."
    requires = ["names"]            # boss/quest scope: skip when a parameter is empty
    sql = "SELECT ..."

A rule returns one row per finding; no rows means the rule passed.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .errors import ConfigError

SCOPES = ("global", "boss", "quest")
SEVERITIES = ("error", "warn", "info")


@dataclass
class Rule:
    name: str
    scope: str
    severity: str
    title: str
    description: str
    sql: str
    requires: list[str] = field(default_factory=list)
    file: str = ""


def load_rules(directory: Path) -> tuple[dict[str, Rule], dict[str, str]]:
    rules: dict[str, Rule] = {}
    macros: dict[str, str] = {}
    files = sorted(directory.glob("*.toml"))
    if not files:
        raise ConfigError(f"{directory}: no rule files")
    for f in files:
        try:
            data = tomllib.loads(f.read_text(encoding="utf-8"))
        except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
            raise ConfigError(f"{f}: {e}") from e
        for k, v in data.get("macro", {}).items():
            if k in macros:
                raise ConfigError(f"{f}: duplicate macro '{k}'")
            macros[k] = str(v)
        for name, spec in data.get("rule", {}).items():
            if name in rules:
                raise ConfigError(f"{f}: duplicate rule '{name}'")
            scope = str(spec.get("scope", ""))
            sev = str(spec.get("severity", ""))
            if scope not in SCOPES:
                raise ConfigError(f"{f}: rule {name}: scope must be one of {SCOPES}")
            if sev not in SEVERITIES:
                raise ConfigError(f"{f}: rule {name}: severity must be one of {SEVERITIES}")
            if not spec.get("sql") or not spec.get("title"):
                raise ConfigError(f"{f}: rule {name}: 'sql' and 'title' are required")
            rules[name] = Rule(
                name, scope, sev, str(spec["title"]), str(spec.get("description", "")), str(spec["sql"]),
                [str(x) for x in spec.get("requires", [])], f.name,
            )
    return rules, macros
