"""Shared helpers: typed DBC rows (through ops/clientpatch), TSV export files, TSV output."""

from __future__ import annotations

import csv
import sys
from pathlib import Path

_CLIENTPATCH = Path(__file__).resolve().parents[2] / "clientpatch"
BINDINGS = _CLIENTPATCH / "bindings" / "1.12.1.5875"
if str(_CLIENTPATCH) not in sys.path:
    sys.path.insert(0, str(_CLIENTPATCH))

from clientpatch.binding import load_binding  # noqa: E402
from clientpatch.wdbc import Table  # noqa: E402


def load_typed(dbc_dir: Path, name: str) -> list[dict]:
    """Rows of ``<dbc_dir>/<name>.dbc`` as dicts, using the clientpatch binding of that DBC."""
    binding = load_binding(BINDINGS / f"{name}.toml")
    table = Table.read(Path(dbc_dir) / f"{name}.dbc", binding)
    names = [c.name for c in binding.columns]
    return [dict(zip(names, row.values)) for row in table.rows]


def has_binding(name: str) -> bool:
    return (BINDINGS / f"{name}.toml").is_file()


def unescape(cell: str):
    if cell == "NULL":
        return None
    out, i = [], 0
    table = {"t": "\t", "n": "\n", "0": "\0", "\\": "\\"}
    while i < len(cell):
        ch = cell[i]
        if ch == "\\" and i + 1 < len(cell):
            out.append(table.get(cell[i + 1], cell[i + 1]))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def read_tsv(path: Path) -> list[dict]:
    """A database export (mariadb -B output with a header line) as a list of dicts."""
    with open(path, encoding="utf-8", errors="replace", newline="") as f:
        lines = f.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        return []
    cols = lines[0].split("\t")
    rows = []
    for ln in lines[1:]:
        cells = ln.split("\t")
        if len(cells) != len(cols):
            continue  # a line broken by an embedded newline; the exports avoid such columns
        rows.append({c: unescape(v) for c, v in zip(cols, cells)})
    return rows


def write_tsv(path: Path, header: list[str], rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        w.writerow(header)
        for r in rows:
            w.writerow(["" if v is None else v for v in r])


def to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None
