"""Expected lists ("Soll-Listen"): what a reference says the database should hold.

One TOML file per instance or topic, in Git, with **ids, names and numbers
only** (no quotes or lore from the source)::

    [instance]
    id = "tower-of-karazhan"
    name = "Tower of Karazhan"
    source = "https://turtle-wow.fandom.com/wiki/Tower_of_Karazhan"
    source_date = "2026-09-29"
    maps = [814]                      # optional: the map ids of the instance (spawns elsewhere are reported)
    allow_elsewhere = ["Some Item"]   # optional: drops from other NPCs are fine

    [[boss]]
    entry = 61939                     # creature_template.entry
    name = "Keeper Gnarlmoon"
    spawn_optional = false            # true for bosses that are summoned
    rank = 3                          # optional: expected creature_template.rank
    loot = ["Item name", "Other item"]

    [[quest]]
    entry = 42023
    title = "Guile of Nature"
    giver = 62631                     # optional creature entry
    ender = 62631                     # optional creature entry

    [[scripted_quest]]                # started or completed by a script, not by a giver row
    entry = 12345
    via = "eluna"                     # script | event | eluna | ...  (required)
    starts = true                     # skip the starter check (default true)
    ends = true                       # skip the turn-in check (default true)
    note = "why"                      # optional

    [[summoned_boss]]                 # a script summons it: no spawn row on purpose
    entry = 11502
    via = "cpp"                       # cpp | eluna | eventai | ...  (required)
    note = "file:line"                # optional

    [[credited_npc]]                  # a helper NPC that C++ or Eluna credits (kill credit)
    entry = 60301
    via = "cpp"                       # cpp | eluna | ...  (required)
    note = "file:line"                # optional
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
    rank: int | None = None


@dataclass
class Quest:
    entry: int
    title: str
    giver: int | None = None
    ender: int | None = None


@dataclass
class Scripted:
    """A quest the database cannot show a starter or turn-in for: a script,
    an event or Eluna handles it. Named here so the global rules skip it."""

    entry: int
    via: str
    starts: bool = True
    ends: bool = True
    note: str = ""


@dataclass
class Summoned:
    """A boss a script summons (C++, Eluna, EventAI): it has no spawn row on purpose."""

    entry: int
    via: str
    note: str = ""


@dataclass
class Credited:
    """A helper NPC that C++ (or Eluna) credits: the database cannot show it."""

    entry: int
    via: str
    note: str = ""


@dataclass
class Expected:
    id: str
    name: str
    source: str
    source_date: str
    allow_elsewhere: list[str]
    maps: list[int]
    bosses: list[Boss]
    quests: list[Quest]
    scripted: list[Scripted]
    summoned: list[Summoned]
    credited: list[Credited]
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
            Boss(
                _int(path, "boss.entry", b.get("entry")), str(b.get("name", "")), bool(b.get("spawn_optional", False)), loot,
                None if b.get("rank") is None else _int(path, "boss.rank", b.get("rank")),
            )
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
    scripted = []
    for s in data.get("scripted_quest", []):
        if not s.get("via"):
            raise ConfigError(f"{path}: scripted_quest {s.get('entry')}: 'via' is required (script, event, eluna, ...)")
        scripted.append(Scripted(_int(path, "scripted_quest.entry", s.get("entry")), str(s["via"]), bool(s.get("starts", True)), bool(s.get("ends", True)), str(s.get("note", ""))))
    summoned = []
    for s in data.get("summoned_boss", []):
        if not s.get("via"):
            raise ConfigError(f"{path}: summoned_boss {s.get('entry')}: 'via' is required (cpp, eluna, eventai, ...)")
        summoned.append(Summoned(_int(path, "summoned_boss.entry", s.get("entry")), str(s["via"]), str(s.get("note", ""))))
    credited = []
    for s in data.get("credited_npc", []):
        if not s.get("via"):
            raise ConfigError(f"{path}: credited_npc {s.get('entry')}: 'via' is required (cpp, eluna, ...)")
        credited.append(Credited(_int(path, "credited_npc.entry", s.get("entry")), str(s["via"]), str(s.get("note", ""))))
    if not bosses and not quests and not scripted and not summoned and not credited:
        raise ConfigError(f"{path}: no [[boss]], [[quest]], [[scripted_quest]], [[summoned_boss]] or [[credited_npc]] entries")
    return Expected(
        id=str(inst["id"]),
        name=str(inst["name"]),
        source=str(inst["source"]),
        source_date=str(inst["source_date"]),
        allow_elsewhere=[str(x) for x in inst.get("allow_elsewhere", [])],
        maps=[_int(path, "instance.maps", m) for m in inst.get("maps", [])],
        bosses=bosses,
        quests=quests,
        scripted=scripted,
        summoned=summoned,
        credited=credited,
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
