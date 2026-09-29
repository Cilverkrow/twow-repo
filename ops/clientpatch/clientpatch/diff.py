"""dbcdiff: field-level comparison of two versions of one DBC.

The build compares every changed DBC with its base and fails when a
difference was not declared by a delta. That catches a wrong binding,
a writer bug, or a delta that touched more than it said.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

from .delta import Touched
from .wdbc import Table


@dataclass(frozen=True)
class Diff:
    dbc: str
    key: tuple
    column: str
    old: object
    new: object
    kind: str  # changed | inserted | removed

    def key_text(self) -> str:
        return ":".join(str(k) for k in self.key)


def _same(a, b) -> bool:
    if isinstance(a, float) and isinstance(b, float):
        return a == b or (a != a and b != b)  # NaN == NaN for diff purposes
    return a == b


def dbcdiff(base: Table, new: Table) -> list[Diff]:
    b = base.binding
    out: list[Diff] = []
    base_keys = set(base.keys())
    new_keys = set(new.keys())
    for key in sorted(new_keys | base_keys):
        old_row = base.find(key) if key in base_keys else None
        new_row = new.find(key) if key in new_keys else None
        for i, col in enumerate(b.columns):
            if old_row is None:
                out.append(Diff(b.dbc, key, col.name, None, new_row.values[i], "inserted"))
            elif new_row is None:
                out.append(Diff(b.dbc, key, col.name, old_row.values[i], None, "removed"))
            elif not _same(old_row.values[i], new_row.values[i]):
                out.append(Diff(b.dbc, key, col.name, old_row.values[i],
                                new_row.values[i], "changed"))
    return out


def undeclared(diffs: list[Diff], touched: Touched) -> list[Diff]:
    bad = []
    for d in diffs:
        if d.kind == "inserted" and d.key in touched.inserted:
            continue
        if d.kind == "changed" and (d.key, d.column) in touched.cells:
            continue
        bad.append(d)
    return bad


def write_review(diffs: list[Diff], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["dbc", "key", "field", "kind", "old", "new"])
        for d in diffs:
            w.writerow([d.dbc, d.key_text(), d.column, d.kind,
                        "" if d.old is None else d.old,
                        "" if d.new is None else d.new])
