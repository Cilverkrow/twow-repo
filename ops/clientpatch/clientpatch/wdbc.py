"""Generic WDBC reader/writer (the DBC format of the 1.x-3.x clients).

File layout::

    char[4] magic = "WDBC"
    uint32  record_count
    uint32  field_count
    uint32  record_size
    uint32  string_block_size
    record_count * record_size bytes of records
    string_block_size bytes of NUL-terminated strings (offset 0 is "")

Round trip guarantee: a table that is read and written without changes is
written back byte for byte. Unchanged rows keep their original record bytes,
the original string block is kept as a prefix, and new strings are appended.
"""

from __future__ import annotations

import bisect
import struct
from dataclasses import dataclass, field
from pathlib import Path

from .binding import Binding
from .errors import LayoutError

MAGIC = b"WDBC"
HEADER = struct.Struct("<4s4I")
STRING_ENCODING = "utf-8"


def _decode(raw: bytes) -> str:
    # surrogateescape keeps any non-UTF-8 byte sequence intact on write.
    return raw.decode(STRING_ENCODING, errors="surrogateescape")


def _encode(value: str) -> bytes:
    return value.encode(STRING_ENCODING, errors="surrogateescape")


@dataclass
class Row:
    values: list
    raw: bytes | None = None  # original record bytes, None once modified/new
    string_offsets: dict[int, int] = field(default_factory=dict)  # col -> orig offset


class Table:
    def __init__(self, binding: Binding, rows: list[Row], string_block: bytes):
        self.binding = binding
        self.rows = rows
        self.string_block = string_block
        self._rebuild_index()

    # ---- reading -------------------------------------------------------

    @classmethod
    def read(cls, path: Path, binding: Binding) -> "Table":
        data = Path(path).read_bytes()
        return cls.from_bytes(data, binding, str(path))

    @classmethod
    def from_bytes(cls, data: bytes, binding: Binding, name: str = "<bytes>") -> "Table":
        if len(data) < HEADER.size:
            raise LayoutError(f"{name}: file too short for a WDBC header")
        magic, count, fields, rsize, ssize = HEADER.unpack_from(data)
        if magic != MAGIC:
            raise LayoutError(f"{name}: not a WDBC file (magic {magic!r})")
        if fields != binding.field_count or rsize != binding.record_size:
            raise LayoutError(
                f"{name}: header says {fields} fields / {rsize} bytes per record, "
                f"binding {binding.dbc} ({binding.build}) expects "
                f"{binding.field_count} / {binding.record_size}. "
                "Wrong client build or wrong binding - stop and check the base."
            )
        expected = HEADER.size + count * rsize + ssize
        if len(data) != expected:
            raise LayoutError(f"{name}: size {len(data)} != header-derived {expected}")
        rec = binding.record_struct
        block_start = HEADER.size + count * rsize
        block = data[block_start:]
        string_cols = [i for i, c in enumerate(binding.columns) if c.kind == "string"]
        rows: list[Row] = []
        for n in range(count):
            off = HEADER.size + n * rsize
            raw = data[off : off + rsize]
            values = list(rec.unpack(raw))
            offsets: dict[int, int] = {}
            for i in string_cols:
                o = values[i]
                if o >= len(block) and not (o == 0 and len(block) == 0):
                    raise LayoutError(
                        f"{name}: row {n} column {binding.columns[i].name} points "
                        f"outside the string block ({o} >= {len(block)})"
                    )
                end = block.find(b"\0", o)
                values[i] = _decode(block[o : end if end >= 0 else len(block)])
                offsets[i] = o
            rows.append(Row(values=values, raw=raw, string_offsets=offsets))
        return cls(binding, rows, block)

    # ---- index ---------------------------------------------------------

    def _key_of(self, values: list) -> tuple:
        return tuple(values[i] for i in self.binding.key_indexes())

    def _rebuild_index(self) -> None:
        self._index: dict[tuple, list[int]] = {}
        for pos, row in enumerate(self.rows):
            self._index.setdefault(self._key_of(row.values), []).append(pos)

    def keys(self) -> list[tuple]:
        return [self._key_of(r.values) for r in self.rows]

    def find(self, key: tuple) -> Row | None:
        hits = self._index.get(key, [])
        if len(hits) > 1:
            raise LayoutError(
                f"{self.binding.dbc}: key {key} is not unique ({len(hits)} rows)"
            )
        return self.rows[hits[0]] if hits else None

    def has_key(self, key: tuple) -> bool:
        return key in self._index

    def get(self, key: tuple, column: str):
        row = self.find(key)
        return None if row is None else row.values[self.binding.index(column)]

    # ---- mutation ------------------------------------------------------

    def set(self, key: tuple, column: str, value) -> None:
        row = self.find(key)
        if row is None:
            raise LayoutError(f"{self.binding.dbc}: no row with key {key}")
        i = self.binding.index(column)
        row.values[i] = value
        row.raw = None
        row.string_offsets.pop(i, None)

    def insert(self, values: list) -> None:
        """Insert a new row. Rows with a single integer key stay sorted by key;
        other tables get the row appended."""
        if len(values) != self.binding.field_count:
            raise LayoutError(f"{self.binding.dbc}: insert with wrong column count")
        key = self._key_of(values)
        if self.has_key(key):
            raise LayoutError(f"{self.binding.dbc}: key {key} already exists")
        row = Row(values=list(values))
        if len(self.binding.key) == 1:
            keys = [self._key_of(r.values) for r in self.rows]
            pos = bisect.bisect_right(keys, key) if keys == sorted(keys) else len(keys)
        else:
            pos = len(self.rows)
        self.rows.insert(pos, row)
        self._rebuild_index()

    def group_by(self, column: str) -> None:
        """Stable regrouping: every row moves directly behind the rows that share
        its value in `column` and come first in the file. Rows of a value that is
        already one contiguous block keep their relative order; rows of a value
        not seen before stay where they fall. Record bytes do not change."""
        i = self.binding.index(column)
        first: dict = {}
        for pos, row in enumerate(self.rows):
            first.setdefault(row.values[i], pos)
        order = sorted(range(len(self.rows)), key=lambda p: (first[self.rows[p].values[i]], p))
        self.rows = [self.rows[p] for p in order]
        self._rebuild_index()

    def move_behind_group(self, column: str, keys: set) -> None:
        """Move only the rows with these keys directly behind the last other row
        that shares their value in `column` (in their original order); every
        other row keeps its position. A group of the base that is already split
        stays as it is (#455: Turtle's SkillRaceClassInfo has skill 137 twice)."""
        i = self.binding.index(column)
        moving = [r for r in self.rows if self._key_of(r.values) in keys]
        out = [r for r in self.rows if self._key_of(r.values) not in keys]
        for row in moving:
            last = max((p for p, other in enumerate(out) if other.values[i] == row.values[i]), default=None)
            out.insert(len(out) if last is None else last + 1, row)
        self.rows = out
        self._rebuild_index()

    def split_groups(self, column: str) -> dict:
        """{value: number of separate blocks} for every value of `column` whose
        rows are not one contiguous block."""
        i = self.binding.index(column)
        blocks: dict = {}
        prev = object()
        for row in self.rows:
            v = row.values[i]
            if v != prev:
                blocks[v] = blocks.get(v, 0) + 1
                prev = v
        return {v: n for v, n in blocks.items() if n > 1}

    def blank_row(self) -> list:
        return ["" if c.kind == "string" else (0.0 if c.kind == "float" else 0)
                for c in self.binding.columns]

    # ---- writing -------------------------------------------------------

    def to_bytes(self) -> bytes:
        b = self.binding
        rec = b.record_struct
        block = bytearray(self.string_block)
        # Reuse strings that already exist in the block (each NUL-terminated
        # run can be referenced from its start).
        lookup: dict[bytes, int] = {}
        start = 0
        for i, byte in enumerate(block):
            if byte == 0:
                lookup.setdefault(bytes(block[start:i]), start)
                start = i + 1

        def offset_for(text: str) -> int:
            raw = _encode(text)
            if not block:
                block.extend(b"\0")      # offset 0 must be the empty string
                lookup.setdefault(b"", 0)
            if raw in lookup:
                return lookup[raw]
            o = len(block)
            block.extend(raw + b"\0")
            lookup[raw] = o
            return o

        out = bytearray()
        for row in self.rows:
            if row.raw is not None:
                out += row.raw
                continue
            packed = []
            for i, col in enumerate(b.columns):
                v = row.values[i]
                if col.kind == "string":
                    if i in row.string_offsets:
                        packed.append(row.string_offsets[i])
                    else:
                        packed.append(offset_for(v))
                elif col.kind == "float":
                    packed.append(float(v))
                else:
                    packed.append(_fit_int(v, col.code, b.dbc, col.name))
            out += rec.pack(*packed)
        header = HEADER.pack(MAGIC, len(self.rows), b.field_count, b.record_size, len(block))
        return header + bytes(out) + bytes(block)

    def write(self, path: Path) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_bytes(self.to_bytes())


_RANGES = {
    "b": (-(2**7), 2**7 - 1), "B": (0, 2**8 - 1),
    "h": (-(2**15), 2**15 - 1), "H": (0, 2**16 - 1),
    "i": (-(2**31), 2**31 - 1), "I": (0, 2**32 - 1),
}


def _fit_int(v: int, code: str, dbc: str, col: str) -> int:
    """Accept both signed and unsigned spellings of the same bit pattern
    (masks are often written as -1 or 0xFFFFFFFF)."""
    lo, hi = _RANGES[code]
    bits = struct.calcsize(code) * 8
    if lo <= v <= hi:
        return v
    if code.islower() and 0 <= v < 2**bits:          # unsigned spelling -> signed field
        return v - 2**bits if v >= 2 ** (bits - 1) else v
    if code.isupper() and -(2 ** (bits - 1)) <= v < 0:  # signed spelling -> unsigned field
        return v + 2**bits
    raise LayoutError(f"{dbc}.{col}: value {v} does not fit a {bits}-bit field")
