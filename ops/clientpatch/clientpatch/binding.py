"""DBC bindings: the field layout of one DBC file for one client build.

A binding is a TOML file (``bindings/<build>/<Dbc>.toml``). It is the only
place that knows what a DBC looks like; every other module (reader, writer,
deltas, diff, consistency) works on any DBC through its binding. Adding a
DBC therefore means adding a binding file, never changing code.

Binding file format::

    dbc = "Talent"                 # file name without .dbc
    build = "1.12.1.5875"          # client build the layout belongs to
    server_loaded = true           # the core loads this DBC too (coupled release)
    key = ["ID"]                   # column(s) that identify a row
    source = "WoWDBDefs ..."       # provenance, free text

    [[field]]
    name = "SpellRank"
    type = "int32"                 # int8/uint8/int16/uint16/int32/uint32/float/string/locstring
    count = 9                      # optional, array length (default 1)

A ``count`` > 1 expands to columns ``SpellRank[0]`` ... ``SpellRank[8]``.
A ``locstring`` expands to one string column per client locale
(``Name_lang_enUS`` ...) plus an unsigned ``Name_lang_flags`` column.
"""

from __future__ import annotations

import struct
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .errors import BindingError

# Locale order of the 1.12 client's localised string blocks (8 + flags).
LOCALES_112 = ("enUS", "koKR", "frFR", "deDE", "zhCN", "zhTW", "esES", "esMX")

# type name -> (struct code, byte size, kind)
TYPES = {
    "int8": ("b", 1, "int"),
    "uint8": ("B", 1, "int"),
    "int16": ("h", 2, "int"),
    "uint16": ("H", 2, "int"),
    "int32": ("i", 4, "int"),
    "uint32": ("I", 4, "int"),
    "float": ("f", 4, "float"),
    "string": ("I", 4, "string"),  # offset into the string block
}


@dataclass(frozen=True)
class Column:
    name: str
    type: str

    @property
    def code(self) -> str:
        return TYPES[self.type][0]

    @property
    def size(self) -> int:
        return TYPES[self.type][1]

    @property
    def kind(self) -> str:
        return TYPES[self.type][2]


@dataclass
class Binding:
    dbc: str
    build: str
    key: list[str]
    columns: list[Column]
    server_loaded: bool = False
    source: str = ""
    path: Path | None = None
    _index: dict[str, int] = field(default_factory=dict, repr=False)

    def __post_init__(self) -> None:
        seen: dict[str, int] = {}
        for i, col in enumerate(self.columns):
            if col.name in seen:
                raise BindingError(f"{self.dbc}: duplicate column {col.name!r}")
            seen[col.name] = i
        self._index = seen
        if not self.key:
            raise BindingError(f"{self.dbc}: binding has no key")
        for k in self.key:
            if k not in seen:
                raise BindingError(f"{self.dbc}: key column {k!r} does not exist")
            if self.columns[seen[k]].kind != "int":
                raise BindingError(f"{self.dbc}: key column {k!r} must be an integer")

    @property
    def field_count(self) -> int:
        return len(self.columns)

    @property
    def record_size(self) -> int:
        return sum(c.size for c in self.columns)

    @property
    def record_struct(self) -> struct.Struct:
        return struct.Struct("<" + "".join(c.code for c in self.columns))

    def index(self, column: str) -> int:
        try:
            return self._index[column]
        except KeyError:
            raise BindingError(
                f"{self.dbc}: unknown column {column!r} "
                f"(binding {self.path or '?'}; see 'clientpatch columns {self.dbc}')"
            ) from None

    def has(self, column: str) -> bool:
        return column in self._index

    def key_indexes(self) -> list[int]:
        return [self._index[k] for k in self.key]


def _expand(entry: dict, dbc: str) -> list[Column]:
    name = entry.get("name")
    typ = entry.get("type")
    count = entry.get("count", 1)
    if not isinstance(name, str) or not name:
        raise BindingError(f"{dbc}: field without a name: {entry!r}")
    if not isinstance(count, int) or count < 1:
        raise BindingError(f"{dbc}.{name}: count must be a positive integer")
    names = [name] if count == 1 else [f"{name}[{i}]" for i in range(count)]
    if typ == "locstring":
        out: list[Column] = []
        for n in names:
            out += [Column(f"{n}_{loc}", "string") for loc in LOCALES_112]
            out.append(Column(f"{n}_flags", "uint32"))
        return out
    if typ not in TYPES:
        raise BindingError(
            f"{dbc}.{name}: unknown type {typ!r} "
            f"(allowed: {', '.join(sorted(TYPES))}, locstring)"
        )
    return [Column(n, typ) for n in names]


def load_binding(path: Path) -> Binding:
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise BindingError(f"{path}: cannot read binding: {e}") from None
    dbc = data.get("dbc")
    if not isinstance(dbc, str) or dbc != path.stem:
        raise BindingError(f"{path}: 'dbc' must equal the file name ({path.stem!r})")
    columns: list[Column] = []
    for entry in data.get("field", []):
        columns += _expand(entry, dbc)
    if not columns:
        raise BindingError(f"{path}: binding has no fields")
    key = data.get("key")
    if isinstance(key, str):
        key = [key]
    return Binding(
        dbc=dbc,
        build=str(data.get("build", "")),
        key=list(key or []),
        columns=columns,
        server_loaded=bool(data.get("server_loaded", False)),
        source=str(data.get("source", "")),
        path=path,
    )


def load_bindings(directory: Path) -> dict[str, Binding]:
    """All bindings of one build directory, keyed by DBC name."""
    if not directory.is_dir():
        raise BindingError(f"binding directory {directory} does not exist")
    out: dict[str, Binding] = {}
    for p in sorted(directory.glob("*.toml")):
        if p.name.startswith("_"):
            continue
        b = load_binding(p)
        out[b.dbc] = b
    if not out:
        raise BindingError(f"no bindings in {directory}")
    return out
