"""Expected lists ("Soll-Listen"): what a reference says the database should hold.

One TOML file per instance or topic, in Git, with **ids, names and numbers
only** (no quotes or lore from the source)::

    [instance]
    id = "tower-of-karazhan"
    name = "Tower of Karazhan"
    source = "https://turtle-wow.fandom.com/wiki/Tower_of_Karazhan"
    source_date = "2026-09-29"
    allow_elsewhere = ["Some Item"]   # optional: drops from other NPCs are fine

    [[boss]]
    entry = 61939                     # creature_template.entry
    name = "Keeper Gnarlmoon"
    spawn_optional = false            # true for bosses that are summoned
    loot = ["Item name", "Other item"]

    [[quest]]
    entry = 42023
    title = "Guile of Nature"
    giver = 62631                     # optional creature entry
    ender = 62631                     # optional creature entry
"""

from __future__ import annotations

import hashlib
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .errors import ConfigError


@dataclass
class Boss:
    entry: int
    name: str
    spawn_optional: bool = False
    loot: list[str] = field(default_factory=list)


@dataclass
class Quest:
    entry: int
    title: str
    giver: int | None = None
    ender: int | None = None


@dataclass
class Expected:
    id: str
    name: str
    source: str
    source_date: str
    allow_elsewhere: list[str]
    bosses: list[Boss]
    quests: list[Quest]
    sha256: str
    path: str


def _int(path, what, v):
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        raise ConfigError(f"{path}: {what} must be a non-negative integer, got {v!r}")
    return v


def load_expected(path: Path) -> Expected:
    raw = path.read_bytes()
    try:
        data = tomllib.loads(raw.decode("utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        raise ConfigError(f"{path}: {e}") from e
    inst = data.get("instance", {})
    for key in ("id", "name", "source", "source_date"):
        if not inst.get(key):
            raise ConfigError(f"{path}: [instance] missing '{key}' (every list names its source and date)")
    bosses = []
    for b in data.get("boss", []):
        loot = [str(x) for x in b.get("loot", [])]
        if any(not x.strip() for x in loot):
            raise ConfigError(f"{path}: boss {b.get('entry')}: empty loot name")
        bosses.append(
            Boss(_int(path, "boss.entry", b.get("entry")), str(b.get("name", "")), bool(b.get("spawn_optional", False)), loot)
        )
    quests = []
    for q in data.get("quest", []):
        giver = q.get("giver")
        ender = q.get("ender")
        quests.append(
            Quest(
                _int(path, "quest.entry", q.get("entry")),
                str(q.get("title", "")),
                None if giver is None else _int(path, "quest.giver", giver),
                None if ender is None else _int(path, "quest.ender", ender),
            )
        )
    if not bosses and not quests:
        raise ConfigError(f"{path}: no [[boss]] and no [[quest]] entries")
    return Expected(
        id=str(inst["id"]),
        name=str(inst["name"]),
        source=str(inst["source"]),
        source_date=str(inst["source_date"]),
        allow_elsewhere=[str(x) for x in inst.get("allow_elsewhere", [])],
        bosses=bosses,
        quests=quests,
        sha256=hashlib.sha256(raw).hexdigest(),
        path=str(path),
    )


def load_all(paths: list[Path]) -> list[Expected]:
    files: list[Path] = []
    for p in paths:
        files.extend(sorted(p.glob("*.toml")) if p.is_dir() else [p])
    out = [load_expected(f) for f in files]
    ids = [e.id for e in out]
    if len(set(ids)) != len(ids):
        raise ConfigError("duplicate [instance] id among expected files")
    return out
