"""Raw DBC reader for files without a clientpatch binding: fields as unsigned dwords."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path


@dataclass
class RawDbc:
    name: str
    fields: int
    record_size: int
    rows: list[tuple]
    strings: bytes

    def string(self, offset: int) -> str:
        end = self.strings.find(b"\0", offset)
        return self.strings[offset : end if end >= 0 else len(self.strings)].decode("utf-8", errors="replace")

    def signed(self, value: int) -> int:
        return value - 0x100000000 if value >= 0x80000000 else value

    def as_float(self, value: int) -> float:
        return struct.unpack("<f", struct.pack("<I", value))[0]


def read_raw(path: Path) -> RawDbc:
    data = Path(path).read_bytes()
    magic, count, fields, rsize, ssize = struct.unpack_from("<4sIIII", data)
    if magic != b"WDBC":
        raise ValueError(f"{path}: not a WDBC file")
    if fields * 4 != rsize:
        raise ValueError(f"{path}: {fields} fields but {rsize} bytes per record")
    if len(data) != 20 + count * rsize + ssize:
        raise ValueError(f"{path}: size does not match the header")
    rows = list(struct.iter_unpack(f"<{fields}I", data[20 : 20 + count * rsize]))
    return RawDbc(Path(path).stem, fields, rsize, rows, data[20 + count * rsize :])
