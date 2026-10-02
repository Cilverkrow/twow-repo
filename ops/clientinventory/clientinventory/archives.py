"""Archive inventory from the MPQ listings and the hash/block tables.

Input: the client's ``Data`` folder (read-only) and the listings made with
``mpqcli list`` (one text file per archive, names with backslashes). Output:
per-archive facts, file-type histograms and the override chain of each file
(which archives carry the same name, in load order).
"""

from __future__ import annotations

import os
from collections import Counter, defaultdict
from pathlib import Path

from .mpqmini import open_mpq

# Load order of the 1.12 client plus the Turtle archives. Later archives win.
LOAD_ORDER = [
    "base.MPQ", "dbc.MPQ", "fonts.MPQ", "interface.MPQ", "misc.MPQ", "model.MPQ", "sound.MPQ", "speech.MPQ",
    "terrain.MPQ", "texture.MPQ", "wmo.MPQ", "backup.MPQ", "patch.MPQ", "patch-2.MPQ", "patch-3.mpq",
    "patch-4.mpq", "patch-5.mpq", "patch-6.mpq", "patch-7.mpq", "patch-8.mpq", "patch-9.mpq", "patch-X.mpq",
]


def read_listing(path: Path) -> list[str]:
    names = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line and line not in ("(listfile)", "(attributes)", "(signature)"):
            names.append(line)
    return names


def load_listings(lists_dir: Path, order=LOAD_ORDER) -> dict[str, list[str]]:
    out = {}
    for arch in order:
        p = lists_dir / f"{arch}.txt"
        if p.is_file():
            out[arch] = read_listing(p)
    return out


def ext(name: str) -> str:
    base = name.replace("\\", "/").rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[-1].lower() if "." in base else "(none)"


def archive_facts(data_dir: Path, listings: dict[str, list[str]]):
    """One row per archive: size, block count, listed names, how complete the listing is."""
    rows = []
    for arch, names in listings.items():
        p = data_dir / arch
        size = os.path.getsize(p)
        m = open_mpq(p)
        top = Counter(ext(n) for n in names).most_common(4)
        rows.append([
            arch, size, m.files, len(names), m.files - len(names) - 2, m.hash_size,
            " ".join(f"{e}:{c}" for e, c in top),
        ])
    return rows


def override_chains(listings: dict[str, list[str]]):
    """name (lower case) -> archives that carry it, in load order."""
    chain: dict[str, list[str]] = defaultdict(list)
    for arch, names in listings.items():
        for n in names:
            chain[n.lower()].append(arch)
    return chain


def effective_map_files(data_dir: Path, listings: dict[str, list[str]], prefix: str = "world" + chr(92) + "maps" + chr(92)):
    """name (lower case) -> (winning archive, file size) for the names below ``prefix``.

    The last archive in load order that carries a name wins. A winning size of 0 means a later
    patch emptied the file (the tile is gone for the client).
    """
    opened = {}
    eff: dict[str, tuple[str, int]] = {}
    for arch, names in listings.items():
        mpq = None
        for n in names:
            if not n.lower().startswith(prefix):
                continue
            if mpq is None:
                mpq = opened[arch] = open_mpq(data_dir / arch)
            s = mpq.size_of(n)
            if s is not None:
                eff[n.lower()] = (arch, s[1])
    return eff
