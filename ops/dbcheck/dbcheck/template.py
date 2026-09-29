"""SQL template expansion and the read-only guard.

Placeholders in a rule's ``sql``:

``{table}`` / ``{table.column}`` / ``{const.name}``
    from the schema binding (backtick-quoted physical names);
``{%macro}``
    a macro from ``[macro]`` in a rules file, expanded first (macros may
    contain the other placeholders);
``{@param}``
    a value of the current expected boss or instance. Integers are checked,
    strings are quoted here; nothing from an expected file reaches the SQL
    unescaped.
"""

from __future__ import annotations

import re

from .binding import Binding
from .errors import ConfigError

_PLACEHOLDER = re.compile(r"\{([%@]?)([A-Za-z_][A-Za-z0-9_]*)(?:\.([A-Za-z_][A-Za-z0-9_]*))?\}")
_SELECT = re.compile(r"^\s*SELECT\b", re.IGNORECASE)
_FORBIDDEN = re.compile(
    r"\b(INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|CREATE|TRUNCATE|GRANT|CALL|INTO\s+OUTFILE|INTO\s+DUMPFILE|LOAD_FILE|SLEEP|BENCHMARK)\b",
    re.IGNORECASE,
)


def sql_string(value: str) -> str:
    """Quote a string literal. Backslashes and control characters are refused
    so the result means the same in MariaDB and SQLite."""
    if "\\" in value or any(ord(c) < 32 for c in value):
        raise ConfigError(f"unsupported character in expected value: {value!r}")
    return "'" + value.replace("'", "''") + "'"


def sql_int_list(values) -> str:
    out = []
    for v in values:
        if isinstance(v, bool) or not isinstance(v, int):
            raise ConfigError(f"expected an integer, got {v!r}")
        out.append(str(v))
    return ",".join(out) if out else "-1"  # never NULL: NOT IN (NULL) matches nothing


def sql_string_list(values) -> str:
    return ",".join(sql_string(str(v).lower()) for v in values) if values else "''"  # never NULL: NOT IN (NULL) matches nothing


def sql_string_table(values) -> str:
    """A one-column derived table of the given strings (portable UNION ALL)."""
    if not values:
        return "SELECT NULL AS expected FROM (SELECT 1 AS one) d WHERE 1=0"
    parts = [f"SELECT {sql_string(str(v))} AS expected" for v in values]
    return " UNION ALL ".join(parts)


def expand(sql: str, binding: Binding, macros: dict[str, str], params: dict[str, str]) -> str:
    """Expand macros, then params, then binding names. Raises on unknown names."""
    for _ in range(4):  # macros may contain macros; bounded so a cycle fails
        if "{%" not in sql:
            break

        def macro(m):
            if m.group(1) != "%":
                return m.group(0)
            if m.group(2) not in macros:
                raise ConfigError(f"unknown macro '{m.group(2)}'")
            return macros[m.group(2)]

        sql = _PLACEHOLDER.sub(macro, sql)
    if "{%" in sql:
        raise ConfigError("macro expansion did not terminate")

    def sub(m):
        kind, a, b = m.group(1), m.group(2), m.group(3)
        if kind == "@":
            if a not in params:
                raise ConfigError(f"unknown parameter '{a}'")
            return params[a]
        if a == "const" and b:
            return binding.const(b)
        if b:
            return binding.column(a, b)
        return binding.table(a)

    return _PLACEHOLDER.sub(sub, sql)


_LITERAL = re.compile(r"'(?:[^']|'')*'")


def check_readonly(sql: str, where: str) -> None:
    # String literals (item names such as "Call of the Wild") are not code.
    body = _LITERAL.sub("''", sql).strip().rstrip(";").strip()
    if not _SELECT.match(body) or ";" in body or _FORBIDDEN.search(body):
        raise ConfigError(f"{where}: query must be a single read-only SELECT")
