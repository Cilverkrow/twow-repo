"""Row/field deltas: the only source format for our client changes.

Layout: ``changes/<Dbc>/NNNN_<description>.csv`` - one directory per DBC,
files applied in name order. Every file is a CSV with this header::

    op,key,field,value,note

``op``
    ``insert``  create row ``key``; ``value`` is empty (all zero/empty) or
                ``copy:<key>`` (start from a copy of an existing row);
                ``field`` stays empty.
    ``set``     set one column of an existing (or earlier inserted) row.
``key``
    The row key; composite keys are joined with ``:`` (``3:7``).
``field``
    Column name as the binding expands it (``SpellRank[0]``,
    ``Name_lang_enUS``); ``clientpatch columns <Dbc>`` lists them.
``value``
    Integer (decimal or ``0x..``), float, or text. Text understands ``\\n``,
    ``\\t`` and ``\\\\``. ``sql:<source>.<column>`` takes the value from the
    server SQL export of that source, for the same key - the server stays the
    single source of truth for numbers it owns.
``note``
    Free text: issue, reason, ``code-values`` entry. Not used by the build.

Lines whose first cell starts with ``#`` are comments. Deleting rows is not
supported on purpose: the client may reference any row, and the server keeps
its own copy of shared DBCs.
"""

from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass, field
from pathlib import Path

from .binding import Binding, Column
from .errors import ClientPatchError, DeltaError
from .wdbc import Table

HEADER = ["op", "key", "field", "value", "note"]
FILE_RE = re.compile(r"^\d{4}_[A-Za-z0-9_.-]+\.csv$")


@dataclass
class Touched:
    """What the deltas declared, so dbcdiff can reject anything else."""

    cells: set[tuple[tuple, str]] = field(default_factory=set)
    inserted: set[tuple] = field(default_factory=set)

    def keys(self) -> set[tuple]:
        return {k for k, _ in self.cells} | set(self.inserted)


def parse_int(text: str) -> int:
    t = text.strip()
    try:
        return int(t, 0)
    except ValueError:
        raise DeltaError(f"not an integer: {text!r}") from None


def parse_key(binding: Binding, text: str) -> tuple:
    parts = text.strip().split(":")
    if len(parts) != len(binding.key):
        raise DeltaError(
            f"{binding.dbc}: key {text!r} has {len(parts)} part(s), "
            f"the binding key is {':'.join(binding.key)}"
        )
    return tuple(parse_int(p) for p in parts)


def unescape(text: str) -> str:
    out, i = [], 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append({"n": "\n", "t": "\t", "\\": "\\"}.get(nxt, "\\" + nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def convert(col: Column, text: str):
    if col.kind == "string":
        return unescape(text)
    if col.kind == "float":
        try:
            return float(text.strip())
        except ValueError:
            raise DeltaError(f"column {col.name}: not a number: {text!r}") from None
    return parse_int(text)


def list_files(changes_dir: Path, dbc: str) -> list[Path]:
    d = changes_dir / dbc
    if not d.is_dir():
        return []
    files = sorted(p for p in d.iterdir() if p.suffix.lower() == ".csv")
    for p in files:
        if not FILE_RE.match(p.name):
            raise DeltaError(f"{p}: file name must look like NNNN_description.csv")
    return files


def changed_dbcs(changes_dir: Path) -> list[str]:
    if not changes_dir.is_dir():
        return []
    return sorted(
        p.name for p in changes_dir.iterdir()
        if p.is_dir() and any(q.suffix.lower() == ".csv" for q in p.iterdir())
    )


def read_ops(path: Path) -> list[tuple[int, dict]]:
    text = path.read_text(encoding="utf-8-sig")
    lines = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
    reader = csv.DictReader(io.StringIO("\n".join(lines)))
    if reader.fieldnames is None or [f.strip() for f in reader.fieldnames] != HEADER:
        raise DeltaError(f"{path}: header must be exactly {','.join(HEADER)}")
    out = []
    for n, row in enumerate(reader, start=2):
        out.append((n, {k.strip(): (v or "") for k, v in row.items() if k}))
    return out


def apply_file(table: Table, path: Path, sql, touched: Touched) -> int:
    b = table.binding
    count = 0
    for line, row in read_ops(path):
        where = f"{path}:{line}"
        op = row["op"].strip()
        try:
            key = parse_key(b, row["key"])
            if op == "insert":
                if row["field"].strip():
                    raise DeltaError("insert takes no field")
                value = row["value"].strip()
                if value.startswith("copy:"):
                    src = parse_key(b, value[5:])
                    base = table.find(src)
                    if base is None:
                        raise DeltaError(f"copy source {src} does not exist")
                    values = list(base.values)
                elif value:
                    raise DeltaError("insert value must be empty or copy:<key>")
                else:
                    values = table.blank_row()
                for i, idx in enumerate(b.key_indexes()):
                    values[idx] = key[i]
                table.insert(values)
                touched.inserted.add(key)
            elif op == "set":
                column = row["field"].strip()
                col = b.columns[b.index(column)]
                if column in b.key:
                    raise DeltaError("key columns cannot be changed with set")
                raw = row["value"]
                if raw.strip().startswith("sql:"):
                    if sql is None:
                        raise DeltaError("sql: value but no SQL exports were given (--sql)")
                    value = sql.resolve(raw.strip()[4:], key, col)
                else:
                    value = convert(col, raw)
                table.set(key, column, value)
                touched.cells.add((key, column))
            else:
                raise DeltaError(f"unknown op {op!r} (insert, set)")
        except ClientPatchError as e:
            raise DeltaError(f"{where}: {e}") from None
        count += 1
    return count


def apply_all(table: Table, changes_dir: Path, sql) -> tuple[Touched, list[Path]]:
    touched = Touched()
    files = list_files(changes_dir, table.binding.dbc)
    for p in files:
        apply_file(table, p, sql, touched)
    return touched, files
