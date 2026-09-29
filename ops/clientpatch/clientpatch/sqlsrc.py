"""Server SQL sources: read-only exports of world tables as TSV.

``sql/sources.toml`` declares each source once::

    [source.map_template]
    query = "SELECT entry, map_type, map_name FROM map_template"
    key = "entry"

``clientpatch export-sql`` runs every query through a MySQL/MariaDB client
command the operator supplies (``--mysql-cmd`` or ``CLIENTPATCH_MYSQL``) and
writes ``<dir>/<source>.tsv`` in the client's batch format (``-B``: tab
separated, header line, ``NULL``, backslash escapes). The tool itself never
holds credentials and never writes to a database: queries must be a single
SELECT.
"""

from __future__ import annotations

import re
import shlex
import subprocess
import tomllib
from dataclasses import dataclass
from pathlib import Path

from .binding import Column
from .delta import convert, parse_int
from .errors import SqlSourceError

_SELECT = re.compile(r"^\s*SELECT\b", re.IGNORECASE)
_FORBIDDEN = re.compile(
    r"\b(INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|CREATE|TRUNCATE|GRANT|INTO\s+OUTFILE|LOAD_FILE)\b",
    re.IGNORECASE,
)


@dataclass
class Source:
    name: str
    query: str
    key: str


def load_sources(path: Path) -> dict[str, Source]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    out = {}
    for name, spec in data.get("source", {}).items():
        q = str(spec.get("query", ""))
        if not _SELECT.match(q) or ";" in q or _FORBIDDEN.search(q):
            raise SqlSourceError(f"{path}: source {name}: query must be a single read-only SELECT")
        if not spec.get("key"):
            raise SqlSourceError(f"{path}: source {name}: missing key column")
        out[name] = Source(name=name, query=q, key=str(spec["key"]))
    return out


def _unescape_tsv(cell: str):
    if cell == "NULL":
        return None
    out, i = [], 0
    while i < len(cell):
        ch = cell[i]
        if ch == "\\" and i + 1 < len(cell):
            out.append({"t": "\t", "n": "\n", "0": "\0", "\\": "\\"}.get(cell[i + 1], cell[i + 1]))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def read_tsv(path: Path) -> tuple[list[str], list[list]]:
    text = path.read_text(encoding="utf-8")
    lines = [ln for ln in text.split("\n") if ln != ""]
    if not lines:
        raise SqlSourceError(f"{path}: empty export (no header line)")
    header = lines[0].split("\t")
    rows = []
    for n, ln in enumerate(lines[1:], start=2):
        cells = ln.split("\t")
        if len(cells) != len(header):
            raise SqlSourceError(f"{path}:{n}: {len(cells)} cells, header has {len(header)}")
        rows.append([_unescape_tsv(c) for c in cells])
    return header, rows


class SqlData:
    """Loaded exports, indexed by the source's key column."""

    def __init__(self, sources: dict[str, Source], tsv_dir: Path):
        self.sources = sources
        self.dir = tsv_dir
        self._tables: dict[str, tuple[list[str], dict[int, dict]]] = {}

    def table(self, name: str) -> tuple[list[str], dict[int, dict]]:
        if name in self._tables:
            return self._tables[name]
        if name not in self.sources:
            raise SqlSourceError(f"unknown SQL source {name!r} (declare it in sql/sources.toml)")
        path = self.dir / f"{name}.tsv"
        if not path.is_file():
            raise SqlSourceError(f"{path} is missing - run 'clientpatch export-sql' first")
        header, rows = read_tsv(path)
        key = self.sources[name].key
        if key not in header:
            raise SqlSourceError(f"{path}: key column {key!r} not in export header")
        ki = header.index(key)
        indexed: dict[int, dict] = {}
        for r in rows:
            k = parse_int(r[ki])
            if k in indexed:
                raise SqlSourceError(f"{path}: duplicate key {k}")
            indexed[k] = dict(zip(header, r))
        self._tables[name] = (header, indexed)
        return self._tables[name]

    def resolve(self, ref: str, key: tuple, col: Column):
        """Value of ``<source>.<column>`` for the row with the same key."""
        if "." not in ref:
            raise SqlSourceError(f"sql reference {ref!r} must be <source>.<column>")
        source, column = ref.split(".", 1)
        if len(key) != 1:
            raise SqlSourceError(f"sql:{ref}: only single-column keys can be resolved")
        header, rows = self.table(source)
        if column not in header:
            raise SqlSourceError(f"sql:{ref}: column {column!r} not in the {source} export")
        row = rows.get(key[0])
        if row is None:
            raise SqlSourceError(f"sql:{ref}: server has no row {key[0]}")
        value = row[column]
        if value is None:
            raise SqlSourceError(f"sql:{ref}: server value for {key[0]} is NULL")
        return convert(col, value)


def export(sources: dict[str, Source], out_dir: Path, mysql_cmd: str) -> list[Path]:
    """Run every source query with the operator's client command (batch mode)."""
    if not mysql_cmd:
        raise SqlSourceError(
            "no MySQL command. Pass --mysql-cmd or set CLIENTPATCH_MYSQL, e.g. "
            "'docker compose -f deploy/compose/docker-compose.yml exec -T db "
            "mariadb --defaults-extra-file=<file> -B tw_world'"
        )
    base = shlex.split(mysql_cmd)
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for s in sources.values():
        try:
            res = subprocess.run(base + ["-B", "-e", s.query], capture_output=True, check=False)
        except OSError as e:
            raise SqlSourceError(f"cannot run {base[0]!r}: {e}") from None
        if res.returncode != 0:
            raise SqlSourceError(f"export of {s.name} failed: {res.stderr.decode(errors='replace').strip()}")
        p = out_dir / f"{s.name}.tsv"
        p.write_bytes(res.stdout)
        written.append(p)
    return written
