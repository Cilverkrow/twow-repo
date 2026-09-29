"""Schema bindings: logical names -> physical tables and columns.

A binding file (``bindings/<id>.toml``) lets every rule be written against
logical names, so a renamed column or a different schema needs a new binding
file and no rule change::

    id = "tw-world"

    [const]
    boss_rank = 3

    [table.creature_template]
    name = "creature_template"          # optional; defaults to the logical name
    [table.creature_template.columns]
    entry = "entry"
    loot_id = "loot_id"

In a rule, ``{creature_template}`` is the table, ``{creature_template.loot_id}``
the column and ``{const.boss_rank}`` a constant.
"""

from __future__ import annotations

import hashlib
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .errors import ConfigError, SchemaError


@dataclass
class Table:
    logical: str
    physical: str
    columns: dict[str, str]


@dataclass
class Binding:
    id: str
    description: str
    consts: dict[str, int | str]
    tables: dict[str, Table]
    sha256: str = ""
    path: str = ""
    extra: dict = field(default_factory=dict)

    def table(self, logical: str) -> str:
        if logical not in self.tables:
            raise ConfigError(f"binding {self.id}: unknown table '{logical}'")
        return "`" + self.tables[logical].physical + "`"

    def column(self, logical: str, col: str) -> str:
        t = self.tables.get(logical)
        if t is None:
            raise ConfigError(f"binding {self.id}: unknown table '{logical}'")
        if col not in t.columns:
            raise ConfigError(f"binding {self.id}: table '{logical}' has no column '{col}'")
        return "`" + t.columns[col] + "`"

    def const(self, name: str) -> str:
        if name not in self.consts:
            raise ConfigError(f"binding {self.id}: unknown constant '{name}'")
        v = self.consts[name]
        if isinstance(v, int):
            return str(v)
        return "'" + str(v).replace("'", "''") + "'"

    def physical_columns(self) -> list[tuple[str, str]]:
        """Sorted ``(physical table, physical column)`` pairs the binding needs."""
        return sorted({(t.physical, c) for t in self.tables.values() for c in t.columns.values()})


def load_binding(path: Path) -> Binding:
    raw = path.read_bytes()
    try:
        data = tomllib.loads(raw.decode("utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        raise ConfigError(f"{path}: {e}") from e
    if not data.get("id"):
        raise ConfigError(f"{path}: missing 'id'")
    tables = {}
    for logical, spec in data.get("table", {}).items():
        cols = spec.get("columns", {})
        if not cols:
            raise ConfigError(f"{path}: table {logical}: no columns")
        tables[logical] = Table(logical, str(spec.get("name", logical)), {k: str(v) for k, v in cols.items()})
    if not tables:
        raise ConfigError(f"{path}: no tables")
    return Binding(
        id=str(data["id"]),
        description=str(data.get("description", "")),
        consts=dict(data.get("const", {})),
        tables=tables,
        sha256=hashlib.sha256(raw).hexdigest(),
        path=str(path),
    )


def check_schema(binding: Binding, actual: dict[str, set[str]]) -> str:
    """Compare the binding with the database; return the schema fingerprint.

    ``actual`` maps a table name to its column names (lower-cased). Raises
    ``SchemaError`` listing every missing table or column at once.
    """
    missing = []
    for table, col in binding.physical_columns():
        cols = actual.get(table.lower())
        if cols is None:
            missing.append(f"table {table}")
        elif col.lower() not in cols:
            missing.append(f"column {table}.{col}")
    if missing:
        uniq = sorted(set(m for m in missing if m.startswith("table "))) or sorted(set(missing))
        raise SchemaError(
            f"the database does not match binding '{binding.id}': missing "
            + ", ".join(uniq[:12])
            + (" ..." if len(uniq) > 12 else "")
        )
    lines = "\n".join(f"{t}.{c}" for t, c in binding.physical_columns())
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()
