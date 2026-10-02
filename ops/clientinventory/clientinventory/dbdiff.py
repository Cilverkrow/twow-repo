"""DBC against server database: which rows exist on one side only, which core fields differ.

The server has DBC-shaped tables (``map_template``, ``spell_template``, ...) next to the DBC files
it loads. The DBC files are the client's, so a DBC row the table lacks is content the client knows
and the server does not; a table row the DBC lacks is something the client cannot show.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .common import load_typed, read_tsv, to_int
from .dbcraw import read_raw


@dataclass
class Pair:
    label: str
    dbc: object  # column name in the typed rows, or a callable(row) -> value
    db: object  # column name in the export, or a callable(row) -> value
    kind: str = "int"  # int | float | str


@dataclass
class Spec:
    name: str
    dbc_name: str
    table: str
    dbc_key: object
    db_key: object
    pairs: list[Pair] = field(default_factory=list)
    raw: bool = False  # the DBC has no binding: rows come from the raw reader through ``raw_rows``
    name_dbc: str = ""  # column that names a row in the typed/raw DBC rows (for the report)
    name_db: str = ""  # column that names a row in the export


def _get(row, spec):
    return spec(row) if callable(spec) else row.get(spec)


def _norm(v, kind):
    if v is None or v == "":
        return None
    if kind == "int":
        try:
            return (int(float(v)) if isinstance(v, str) else int(v)) & 0xFFFFFFFF  # int32 and uint32 are the same 32 bits
        except (TypeError, ValueError):
            return None
    if kind == "float":
        try:
            return round(float(v), 2)
        except (TypeError, ValueError):
            return None
    return str(v).strip().lower()


@dataclass
class Result:
    spec: Spec
    dbc_rows: int
    db_rows: int
    both: int
    only_dbc: list
    only_db: list
    diffs: dict  # label -> list of (key, dbc value, db value)
    dbc_by_key: dict = field(default_factory=dict)
    db_by_key: dict = field(default_factory=dict)


def compare(spec: Spec, dbc_rows: list[dict], db_rows: list[dict]) -> Result:
    dbc = {}
    for r in dbc_rows:
        k = _norm(_get(r, spec.dbc_key), "int")
        if k is not None:
            dbc[k] = r
    db = {}
    for r in db_rows:
        k = _norm(_get(r, spec.db_key), "int")
        if k is not None:
            db[k] = r
    both = sorted(set(dbc) & set(db))
    diffs = {p.label: [] for p in spec.pairs}
    for k in both:
        for p in spec.pairs:
            a, b = _norm(_get(dbc[k], p.dbc), p.kind), _norm(_get(db[k], p.db), p.kind)
            if a != b:
                diffs[p.label].append((k, a, b))
    return Result(spec, len(dbc), len(db), len(both), sorted(set(dbc) - set(db)), sorted(set(db) - set(dbc)), diffs, dbc, db)


# ---- row adapters for DBCs without a binding --------------------------------------------------

def raw_rows(path: Path, columns: dict[str, tuple[str, int]]):
    """Rows as dicts. ``columns``: name -> (kind, field index); kind is u (unsigned), i (signed), s (string), f (float)."""
    dbc = read_raw(path)
    out = []
    for row in dbc.rows:
        d = {}
        for name, (kind, idx) in columns.items():
            v = row[idx]
            d[name] = dbc.signed(v) if kind == "i" else dbc.string(v) if kind == "s" else dbc.as_float(v) if kind == "f" else v
        out.append(d)
    return out


def e(name):  # typed column of an array: Effect -> lambda row: row["Effect[i]"]
    return name


def idx(name, i):
    return f"{name}[{i}]"


SPELL_PAIRS = [Pair(lbl, d, t) for lbl, d, t in [
    ("School", "School", "school"), ("Category", "Category", "category"), ("CastUI", "CastUI", "castUI"),
    ("Dispel", "DispelType", "dispel"), ("Mechanic", "Mechanic", "mechanic"), ("Attributes", "Attributes", "attributes"),
    ("AttributesEx", "AttributesEx", "attributesEx"), ("AttributesEx2", "AttributesExB", "attributesEx2"),
    ("AttributesEx3", "AttributesExC", "attributesEx3"), ("AttributesEx4", "AttributesExD", "attributesEx4"),
    ("Stances", "ShapeshiftMask", "stances"), ("StancesNot", "ShapeshiftExclude", "stancesNot"), ("Targets", "Targets", "targets"),
    ("TargetCreatureType", "TargetCreatureType", "targetCreatureType"), ("CastingTimeIndex", "CastingTimeIndex", "castingTimeIndex"),
    ("RecoveryTime", "RecoveryTime", "recoveryTime"), ("CategoryRecoveryTime", "CategoryRecoveryTime", "categoryRecoveryTime"),
    ("InterruptFlags", "InterruptFlags", "interruptFlags"), ("AuraInterruptFlags", "AuraInterruptFlags", "auraInterruptFlags"),
    ("ChannelInterruptFlags", "ChannelInterruptFlags", "channelInterruptFlags"), ("ProcFlags", "ProcFlags", "procFlags"),
    ("ProcChance", "ProcChance", "procChance"), ("ProcCharges", "ProcCharges", "procCharges"), ("MaxLevel", "MaxLevel", "maxLevel"),
    ("BaseLevel", "BaseLevel", "baseLevel"), ("SpellLevel", "SpellLevel", "spellLevel"), ("DurationIndex", "DurationIndex", "durationIndex"),
    ("PowerType", "PowerType", "powerType"), ("ManaCost", "ManaCost", "manaCost"), ("RangeIndex", "RangeIndex", "rangeIndex"),
    ("SpellIconID", "SpellIconID", "spellIconId"),
]]
SPELL_PAIRS.append(Pair("Speed", "Speed", "speed", "float"))
for i in range(3):
    n = i + 1
    SPELL_PAIRS += [
        Pair(f"Effect{n}", idx("Effect", i), f"effect{n}"), Pair(f"EffectDieSides{n}", idx("EffectDieSides", i), f"effectDieSides{n}"),
        Pair(f"EffectBasePoints{n}", idx("EffectBasePoints", i), f"effectBasePoints{n}"),
        Pair(f"EffectImplicitTargetA{n}", idx("ImplicitTargetA", i), f"effectImplicitTargetA{n}"),
        Pair(f"EffectImplicitTargetB{n}", idx("ImplicitTargetB", i), f"effectImplicitTargetB{n}"),
        Pair(f"EffectRadiusIndex{n}", idx("EffectRadiusIndex", i), f"effectRadiusIndex{n}"),
        Pair(f"EffectApplyAuraName{n}", idx("EffectAura", i), f"effectApplyAuraName{n}"),
        Pair(f"EffectAuraPeriod{n}", idx("EffectAuraPeriod", i), f"effectAmplitude{n}"),  # the table calls the aura period "amplitude"
        Pair(f"EffectMiscValue{n}", idx("EffectMiscValue", i), f"effectMiscValue{n}"),
        Pair(f"EffectTriggerSpell{n}", idx("EffectTriggerSpell", i), f"effectTriggerSpell{n}"),
    ]
SPELL_PAIRS.append(Pair("Name", "Name_lang_enUS", "name", "str"))

SPECS = [
    Spec("map", "Map", "map_template", "ID", "entry", [
        Pair("name", "MapName_lang_enUS", "map_name", "str"), Pair("type", "InstanceType", "map_type"),
        Pair("players", "MaxPlayers", "player_limit"), Pair("parent", "ParentMapID", "parent"),
    ], name_dbc="MapName_lang_enUS", name_db="map_name"),
    Spec("areatrigger", "AreaTrigger", "areatrigger_template", "ID", "id", [
        Pair("map", "ContinentID", "map_id"), Pair("x", "Pos[0]", "x", "float"), Pair("y", "Pos[1]", "y", "float"),
        Pair("z", "Pos[2]", "z", "float"), Pair("radius", "Radius", "radius", "float"),
        Pair("box_length", "Box_length", "box_x", "float"), Pair("box_width", "Box_width", "box_y", "float"),
        Pair("box_height", "Box_height", "box_z", "float"), Pair("box_yaw", "Box_yaw", "box_orientation", "float"),
    ]),
    Spec("spell", "Spell", "spell_template", "ID", "entry", SPELL_PAIRS, name_dbc="Name_lang_enUS", name_db="name"),
    Spec("skilllineability", "SkillLineAbility", "skill_line_ability", "ID", "id", [
        Pair("skill", "SkillLine", "skill_id"), Pair("spell", "Spell", "spell_id"), Pair("race_mask", "RaceMask", "race_mask"),
        Pair("class_mask", "ClassMask", "class_mask"), Pair("superseded_by", "SupercededBySpell", "superseded_by_spell"),
        Pair("min_rank", "MinSkillLineRank", "req_skill_value"), Pair("acquire", "AcquireMethod", "learn_on_get_skill"),
        Pair("trivial_high", "TrivialSkillLineRankHigh", "max_value"), Pair("trivial_low", "TrivialSkillLineRankLow", "min_value"),
    ]),
    Spec("areatable", "AreaTable", "area_template", "ID", "entry", [
        Pair("map", "map", "map_id"), Pair("zone", "zone", "zone_id"), Pair("explore_flag", "explore", "explore_flag"),
        Pair("flags", "flags", "flags"), Pair("level", "level", "area_level"), Pair("name", "name", "name", "str"),
    ], raw=True, name_dbc="name", name_db="name"),
    Spec("faction", "Faction", "faction", "ID", "id", [
        Pair("rep_index", "rep_index", "reputation_list_id"), Pair("name", "name", "name1", "str"),
    ], raw=True, name_dbc="name", name_db="name1"),
    Spec("factiontemplate", "FactionTemplate", "faction_template", "ID", "id", [
        Pair("faction", "faction", "faction_id"), Pair("flags", "flags", "faction_flags"), Pair("our_mask", "our", "our_mask"),
        Pair("friendly_mask", "friendly", "friendly_mask"), Pair("hostile_mask", "hostile", "hostile_mask"),
    ], raw=True),
    Spec("itemdisplayinfo", "ItemDisplayInfo", "item_display_info", "ID", "ID", [], raw=True),
]

RAW_COLUMNS = {
    "AreaTable": {"ID": ("u", 0), "map": ("u", 1), "zone": ("u", 2), "explore": ("u", 3), "flags": ("u", 4), "level": ("i", 10), "name": ("s", 11)},
    "Faction": {"ID": ("u", 0), "rep_index": ("i", 1), "name": ("s", 19)},
    "FactionTemplate": {"ID": ("u", 0), "faction": ("u", 1), "flags": ("u", 2), "our": ("u", 3), "friendly": ("u", 4), "hostile": ("u", 5)},
    "ItemDisplayInfo": {"ID": ("u", 0)},
}


def run_spec(spec: Spec, dbc_dir: Path, db_dir: Path) -> Result:
    rows = raw_rows(dbc_dir / f"{spec.dbc_name}.dbc", RAW_COLUMNS[spec.dbc_name]) if spec.raw else load_typed(dbc_dir, spec.dbc_name)
    return compare(spec, rows, read_tsv(db_dir / f"{spec.table}.tsv"))


def references(dbc_dir: Path, db_dir: Path):
    """Display ids that server rows use but no DBC row carries (the client would show a blank model)."""
    out = []
    plans = [
        ("creature_template.display_id1-4 -> CreatureDisplayInfo", "CreatureDisplayInfo", "creature_template", ["display_id1", "display_id2", "display_id3", "display_id4"], "entry"),
        ("item_template.display_id -> ItemDisplayInfo", "ItemDisplayInfo", "item_template", ["display_id"], "entry"),
        ("gameobject_template.displayId -> GameObjectDisplayInfo", "GameObjectDisplayInfo", "gameobject_template", ["displayId"], "entry"),
    ]
    for label, dbc_name, table, cols, key in plans:
        ids = {r[0] for r in read_raw(dbc_dir / f"{dbc_name}.dbc").rows}
        missing = {}
        for r in read_tsv(db_dir / f"{table}.tsv"):
            for c in cols:
                v = to_int(r.get(c))
                if v and v not in ids:
                    missing.setdefault(v, []).append(r[key])
        out.append((label, len(ids), missing))
    return out
