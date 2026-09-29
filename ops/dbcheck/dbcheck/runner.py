"""Database runners: the MariaDB client command and SQLite (tests, fixtures).

The tool never holds credentials. For a real database the operator supplies
a client command that reads SQL from stdin, for example::

    docker exec -i <db-container> mariadb -u <ro-user> -p... tw_world

(``--mysql-cmd`` or ``DBCHECK_MYSQL``). ``-B`` (tab separated, header line) is
added when missing. SQLite is used for the synthetic test fixture only.
"""

from __future__ import annotations

import shlex
import sqlite3
import subprocess

from .errors import RunnerError
from .template import check_readonly

_TSV_ESCAPES = {"t": "\t", "n": "\n", "0": "\0", "\\": "\\"}


def unescape_tsv(cell: str):
    if cell == "NULL":
        return None
    out, i = [], 0
    while i < len(cell):
        ch = cell[i]
        if ch == "\\" and i + 1 < len(cell):
            out.append(_TSV_ESCAPES.get(cell[i + 1], cell[i + 1]))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def parse_tsv(text: str) -> tuple[list[str], list[tuple]]:
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        return [], []
    cols = lines[0].split("\t")
    rows = []
    for ln in lines[1:]:
        cells = ln.split("\t")
        if len(cells) != len(cols):
            raise RunnerError(f"client output has {len(cells)} cells, expected {len(cols)}: {ln[:80]!r}")
        rows.append(tuple(unescape_tsv(c) for c in cells))
    return cols, rows


class Runner:
    kind = "abstract"

    def query(self, sql: str) -> tuple[list[str], list[tuple]]:
        raise NotImplementedError

    def schema(self) -> dict[str, set[str]]:
        raise NotImplementedError


class MysqlRunner(Runner):
    kind = "mysql"

    def __init__(self, cmd: str, timeout: int = 600):
        self.argv = shlex.split(cmd)
        if not self.argv:
            raise RunnerError("empty --mysql-cmd")
        if "-B" not in self.argv and "--batch" not in self.argv:
            self.argv.append("-B")
        self.timeout = timeout

    def query(self, sql):
        check_readonly(sql, "runner")
        try:
            p = subprocess.run(
                self.argv, input=sql.strip().rstrip(";") + ";\n", capture_output=True, text=True,
                encoding="utf-8", timeout=self.timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            raise RunnerError(f"database client failed: {e}") from e
        if p.returncode != 0:
            raise RunnerError(f"database client exited {p.returncode}: {p.stderr.strip()[:300]}")
        return parse_tsv(p.stdout)

    def schema(self):
        _, rows = self.query(
            "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = DATABASE()"
        )
        out: dict[str, set[str]] = {}
        for t, c in rows:
            out.setdefault(t.lower(), set()).add(c.lower())
        return out


class SqliteRunner(Runner):
    kind = "sqlite"

    def __init__(self, path: str):
        # Read-only URI: the tool must not be able to change a database file.
        self.con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)

    @classmethod
    def from_connection(cls, con: sqlite3.Connection) -> "SqliteRunner":
        r = cls.__new__(cls)
        r.con = con
        return r

    def query(self, sql):
        check_readonly(sql, "runner")
        try:
            cur = self.con.execute(sql.strip().rstrip(";"))
        except sqlite3.Error as e:
            raise RunnerError(f"sqlite: {e}") from e
        cols = [d[0] for d in cur.description or []]
        rows = [tuple(None if v is None else str(v) for v in r) for r in cur.fetchall()]
        return cols, rows

    def schema(self):
        out: dict[str, set[str]] = {}
        names = [r[0] for r in self.con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        for t in names:
            out[t.lower()] = {r[1].lower() for r in self.con.execute(f'PRAGMA table_info("{t}")')}
        return out
