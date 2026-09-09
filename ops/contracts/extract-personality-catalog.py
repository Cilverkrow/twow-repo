#!/usr/bin/env python3
"""Regenerate the machine-readable personality catalog from the contract.

THE MARKDOWN IS THE SOURCE OF TRUTH.
docs/contracts/personality-context-contract-v1.md owns the trait catalog, the
pools, the strengths and the conflict list. Everything this script writes is
derived and must never be hand-edited -- edit the markdown and re-run:

    python ops/contracts/extract-personality-catalog.py

Outputs:
  contracts/personality/v1/traits.json     -- key / German label / Ollama
                                              instruction / originating section
  services/bot-brain/planner/llm/personality/traits.json
                                           -- a byte copy of the above, embedded
                                              into the Go service. go:embed
                                              cannot reach outside the module,
                                              and the bot-brain image is built
                                              from services/bot-brain alone
  contracts/personality/v1/pools.json      -- race, variant, class and
                                              profession pools plus the numeric
                                              rules from section 4 and 9.2
  modules/mod-bot-brain/src/PersonalityCatalog.h
                                           -- the same pools as ASCII-only C++
                                              tables, so the policy header has
                                              no file to load and no encoding to
                                              worry about at test time

Why a third output rather than letting the header read the JSON: the policy
layer is a pure decision function that has to be linkable into a unit test with
no fixtures, no parser and no path define. Generating both from one parse is
what keeps them from drifting; `--check` fails when a generated file on disk no
longer matches the markdown.

Two things this script has to supply that the markdown does NOT contain, and
which are therefore maintained here by hand:

  * canonical English keys for races, variants, classes and professions. The
    contract deliberately names them in German prose (section 3: "Die
    Bezeichnungen in diesem Dokument sind kanonische Anwendungsschlüssel"),
    but the JSON example in section 12 shows the wire form is `dwarf`,
    `warrior`, `blacksmithing`. The mapping below is that wire form.
  * profession skill ids. Section 14 item 4 says these are pending local
    verification, so an unverified profession carries skill id 0 and is
    matched by key only. `survival` and `gardening` are Turtle-specific and
    genuinely unknown; `jewelcrafting` is 755 upstream but the contract itself
    doubts this server carries the profession at all.
"""

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACT = REPO_ROOT / "docs" / "contracts" / "personality-context-contract-v1.md"
TRAITS_JSON = REPO_ROOT / "contracts" / "personality" / "v1" / "traits.json"
POOLS_JSON = REPO_ROOT / "contracts" / "personality" / "v1" / "pools.json"
CATALOG_H = REPO_ROOT / "modules" / "mod-bot-brain" / "src" / "PersonalityCatalog.h"
# A byte copy of TRAITS_JSON, inside the Go module. go:embed cannot reach outside
# a package directory and the bot-brain Docker build context is
# services/bot-brain alone, so the dialogue prompt builder cannot read the
# contracts/ tree at build or run time. planner/llm/personality has a test
# asserting the two files are identical, so a regeneration that forgot this one
# fails CI rather than leaving bots talking from a stale catalog.
TRAITS_JSON_GO = (REPO_ROOT / "services" / "bot-brain" / "planner" / "llm" /
                  "personality" / "traits.json")

SOURCE_REL = "docs/contracts/personality-context-contract-v1.md"

# German heading -> canonical application key. See the module docstring.
RACE_KEYS = {
    "Mensch": "human",
    "Zwerg": "dwarf",
    "Gnom": "gnome",
    "Nachtelf": "night_elf",
    "Hochelf": "high_elf",
    "Orc": "orc",
    "Tauren": "tauren",
    "Troll": "troll",
    "Untoter": "undead",
    "Goblin": "goblin",
}

VARIANT_KEYS = {
    "Blutelfen-Stil": "blood_elf",
    "Dunkeleisenzwerg": "dark_iron",
    "Wildhammerzwerg": "wildhammer",
    "Waldtroll": "forest",
}

CLASS_KEYS = {
    "Krieger": "warrior",
    "Schurke": "rogue",
    "Jäger": "hunter",
    "Magier": "mage",
    "Hexenmeister": "warlock",
    "Druide": "druid",
    "Schamane": "shaman",
    "Priester": "priest",
    "Paladin": "paladin",
}

# (canonical key, skill id). 0 means "not verified against this server yet".
PROFESSION_KEYS = {
    "Alchemie": ("alchemy", 171),
    "Schmiedekunst": ("blacksmithing", 164),
    "Verzauberkunst": ("enchanting", 333),
    "Ingenieurskunst": ("engineering", 202),
    "Kräuterkunde": ("herbalism", 182),
    "Lederverarbeitung": ("leatherworking", 165),
    "Bergbau": ("mining", 186),
    "Kürschnerei": ("skinning", 393),
    "Schneiderei": ("tailoring", 197),
    "Kochkunst": ("cooking", 185),
    "Angeln": ("fishing", 356),
    "Erste Hilfe": ("first_aid", 129),
    "Überleben": ("survival", 0),
    "Gartenbau": ("gardening", 0),
    "Juwelenschleifen": ("jewelcrafting", 0),
}

# Section 4 and 9.2, transcribed rather than parsed: they are prose-heavy rows
# whose numbers matter more than their wording, and a silent mis-parse of a
# strength would be far worse than a transcription that `--check` cannot catch.
# The parser below asserts the strengths it CAN see in section 4 against these.
STRENGTHS = {"manual": 70, "race_variant": 60, "class": 65, "race": 55, "profession": 45}
QUOTAS = {"race": 3, "race_variant": 1, "class": 2, "profession": 1}
STRENGTH_MIN, STRENGTH_MAX = 20, 80


def read_contract() -> str:
    return CONTRACT.read_text(encoding="utf-8")


def sections(text):
    """Split on markdown headings, yielding (level, title, body)."""
    out = []
    current = None
    for line in text.splitlines():
        m = re.match(r"^(#{2,4})\s+(.*)$", line)
        if m:
            current = [len(m.group(1)), m.group(2).strip(), []]
            out.append(current)
        elif current is not None:
            current[2].append(line)
    return [(lvl, title, "\n".join(body)) for lvl, title, body in out]


def table_rows(body):
    """Yield the data rows of every markdown pipe table in `body` as cell lists."""
    rows = []
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
            continue  # separator
        rows.append(cells)
    return rows


def is_header(cells):
    return cells and cells[0] in ("Schlüssel", "Basisrasse", "Variante", "Klasse", "Beruf",
                                  "Kandidat", "Quelle", "Trait A", "Kombination", "Kanal",
                                  "Tabelle")


def backticked(cell):
    return re.findall(r"`([a-z_]+)`", cell)


def find_section(secs, prefix):
    for lvl, title, body in secs:
        if title.startswith(prefix):
            return title, body
    raise SystemExit(f"contract section {prefix!r} not found")


def parse(text):
    secs = sections(text)

    # --- Section 8: the trait catalog. ------------------------------------
    traits = []
    seen = {}
    for lvl, title, body in secs:
        m = re.match(r"^(8\.\d)\s+(.*)$", title)
        if not m:
            continue
        number, heading = m.group(1), m.group(2)
        for cells in table_rows(body):
            if is_header(cells) or len(cells) < 3:
                continue
            keys = backticked(cells[0])
            if not keys:
                continue
            key = keys[0]
            entry = {
                "key": key,
                "label": cells[1],
                "instruction": cells[2],
                "section": number,
                "section_title": heading,
            }
            if key in seen:
                raise SystemExit(f"trait {key!r} defined twice in section 8")
            seen[key] = entry
            traits.append(entry)

    # --- Sections 5, 5.1, 6, 7: the pools. --------------------------------
    _, body5 = find_section(secs, "5. Rassen-Trait-Pools")
    races = []
    for cells in table_rows(body5):
        if is_header(cells) or len(cells) < 2:
            continue
        races.append({
            "key": RACE_KEYS[cells[0]],
            "label": cells[0],
            "traits": backticked(cells[1]),
        })

    _, body51 = find_section(secs, "5.1 Optionale Rassenvarianten")
    variants = []
    for cells in table_rows(body51):
        if is_header(cells) or len(cells) < 4:
            continue
        variants.append({
            "key": VARIANT_KEYS[cells[0]],
            "label": cells[0],
            "base_race": RACE_KEYS[cells[1]],
            "traits": backticked(cells[2]),
            "activation": cells[3],
        })

    _, body6 = find_section(secs, "6. Klassen-Trait-Pools")
    classes = []
    for cells in table_rows(body6):
        if is_header(cells) or len(cells) < 2:
            continue
        if cells[0] not in CLASS_KEYS:
            continue
        classes.append({
            "key": CLASS_KEYS[cells[0]],
            "label": cells[0],
            "traits": backticked(cells[1]),
        })

    _, body7 = find_section(secs, "7. Berufs-Trait-Pools")
    professions = []
    for cells in table_rows(body7):
        if is_header(cells) or len(cells) < 2:
            continue
        if cells[0] not in PROFESSION_KEYS:
            continue
        key, skill = PROFESSION_KEYS[cells[0]]
        # The second table in section 7 is the "bleibt deaktiviert" list: three
        # columns instead of two, and its rows must not be provisioned until
        # the server is checked (section 14 item 4).
        professions.append({
            "key": key,
            "label": cells[0],
            "skill_id": skill,
            "enabled": len(cells) == 2,
            "traits": backticked(cells[1]),
            **({"note": cells[2]} if len(cells) > 2 else {}),
        })

    # --- Section 9.2: hard conflicts. -------------------------------------
    _, body92 = find_section(secs, "9.2 Harte Konflikte")
    conflicts = []
    for cells in table_rows(body92):
        if is_header(cells) or len(cells) < 3:
            continue
        a, b = backticked(cells[0]), backticked(cells[1])
        if not a or not b:
            continue
        conflicts.append({"a": a[0], "b": b[0], "reason": cells[2]})

    priority = ["manual", "race_variant", "class", "race", "profession"]

    # --- Section 4: cross-check the strengths we transcribed. -------------
    _, body4 = find_section(secs, "4. Profilzusammensetzung")
    seen_strengths = [int(c) for cells in table_rows(body4) for c in cells if c.isdigit()]
    for value in STRENGTHS.values():
        if value not in seen_strengths:
            raise SystemExit(f"strength {value} no longer appears in section 4")

    return {
        "traits": traits,
        "races": races,
        "race_variants": variants,
        "classes": classes,
        "professions": professions,
        "conflicts": conflicts,
        "priority": priority,
    }


def validate(model):
    known = {t["key"] for t in model["traits"]}
    problems = []
    for group, expected in (("races", 6), ("race_variants", 6), ("classes", 5), ("professions", 3)):
        for pool in model[group]:
            if len(pool["traits"]) != expected:
                problems.append(f"{group}/{pool['key']}: {len(pool['traits'])} traits, expected {expected}")
            for key in pool["traits"]:
                if key not in known:
                    problems.append(f"{group}/{pool['key']}: trait {key!r} has no section 8 entry")
    for conflict in model["conflicts"]:
        for key in (conflict["a"], conflict["b"]):
            if key not in known:
                problems.append(f"conflict trait {key!r} has no section 8 entry")
    if problems:
        raise SystemExit("catalog validation failed:\n  " + "\n  ".join(problems))


def build_traits_json(model):
    return {
        "_comment": f"GENERATED by ops/contracts/extract-personality-catalog.py from {SOURCE_REL}. Do not edit.",
        "schema_version": 1,
        "profile_version": 1,
        "source": SOURCE_REL,
        "trait_count": len(model["traits"]),
        "traits": model["traits"],
    }


def build_pools_json(model):
    return {
        "_comment": f"GENERATED by ops/contracts/extract-personality-catalog.py from {SOURCE_REL}. Do not edit.",
        "schema_version": 1,
        "profile_version": 1,
        "source": SOURCE_REL,
        "selection": {
            "hash": "SHA-256(profile_version | profile_seed | source_type | source_key | trait_key)",
            "order": "highest stable value wins, up to the quota",
            "quotas": QUOTAS,
            "strengths": STRENGTHS,
            "strength_min": STRENGTH_MIN,
            "strength_max": STRENGTH_MAX,
            "duplicate_rule": "max of origin strengths, never a sum",
            "conflict_priority": model["priority"],
        },
        "conflicts": model["conflicts"],
        "races": model["races"],
        "race_variants": model["race_variants"],
        "classes": model["classes"],
        "professions": model["professions"],
    }


def cxx_array(name, entries, width):
    lines = []
    for entry in entries:
        traits = ", ".join(f'"{t}"' for t in entry["traits"])
        lines.append(f'    {{ "{entry["key"]}", {{ {traits} }} }},')
    return lines


def build_catalog_header(model):
    o = []
    w = o.append
    w("/*")
    w(" * mod-bot-brain -- personality trait pools, section 5/5.1/6/7 of the")
    w(f" * personality context contract, as ASCII-only C++ tables.")
    w(" *")
    w(" * GENERATED FILE. Do not edit by hand.")
    w(f" * Source of truth: {SOURCE_REL}")
    w(" * Regenerate:      python ops/contracts/extract-personality-catalog.py")
    w(" *")
    w(" * Keys only, no German labels and no Ollama instructions: those live in")
    w(" * contracts/personality/v1/traits.json and belong to the prompt builder.")
    w(" * Keeping this header pure ASCII is what lets the policy layer compile")
    w(" * with no encoding flags and no fixture to load.")
    w(" */")
    w("")
    w("#pragma once")
    w("")
    w("#include <cstddef>")
    w("#include <cstdint>")
    w("")
    w("namespace ai::personality::catalog")
    w("{")
    w("// Section 4: quotas and default strengths. Strengths clamp to [20, 80].")
    w(f"inline constexpr int kStrengthMin = {STRENGTH_MIN};")
    w(f"inline constexpr int kStrengthMax = {STRENGTH_MAX};")
    w(f"inline constexpr int kRaceStrength = {STRENGTHS['race']};")
    w(f"inline constexpr int kVariantStrength = {STRENGTHS['race_variant']};")
    w(f"inline constexpr int kClassStrength = {STRENGTHS['class']};")
    w(f"inline constexpr int kProfessionStrength = {STRENGTHS['profession']};")
    w(f"inline constexpr int kManualStrength = {STRENGTHS['manual']};")
    w("")
    w(f"inline constexpr std::size_t kRaceQuota = {QUOTAS['race']};")
    w(f"inline constexpr std::size_t kClassQuota = {QUOTAS['class']};")
    w(f"inline constexpr std::size_t kProfessionQuota = {QUOTAS['profession']};")
    w(f"inline constexpr std::size_t kVariantQuota = {QUOTAS['race_variant']};")
    w("")
    w("inline constexpr std::size_t kRacePoolSize = 6;")
    w("inline constexpr std::size_t kVariantPoolSize = 6;")
    w("inline constexpr std::size_t kClassPoolSize = 5;")
    w("inline constexpr std::size_t kProfessionPoolSize = 3;")
    w("")
    w("struct RacePool")
    w("{")
    w("    char const* key;")
    w("    char const* traits[kRacePoolSize];")
    w("};")
    w("")
    w("struct VariantPool")
    w("{")
    w("    char const* key;")
    w("    char const* baseRace;   // the variant is ignored on any other race")
    w("    char const* traits[kVariantPoolSize];")
    w("};")
    w("")
    w("struct ClassPool")
    w("{")
    w("    char const* key;")
    w("    char const* traits[kClassPoolSize];")
    w("};")
    w("")
    w("struct ProfessionPool")
    w("{")
    w("    char const* key;")
    w("    std::uint32_t skillId;   // 0 = not verified against this server yet")
    w("    bool enabled;            // section 7's deactivated candidates are false")
    w("    char const* traits[kProfessionPoolSize];")
    w("};")
    w("")
    w("struct ConflictPair")
    w("{")
    w("    char const* a;")
    w("    char const* b;")
    w("};")
    w("")
    w("// Section 5.")
    w("inline constexpr RacePool kRaces[] =")
    w("{")
    for r in model["races"]:
        traits = ", ".join(f'"{t}"' for t in r["traits"])
        w(f'    {{ "{r["key"]}", {{ {traits} }} }},')
    w("};")
    w("")
    w("// Section 5.1.")
    w("inline constexpr VariantPool kRaceVariants[] =")
    w("{")
    for v in model["race_variants"]:
        traits = ", ".join(f'"{t}"' for t in v["traits"])
        w(f'    {{ "{v["key"]}", "{v["base_race"]}", {{ {traits} }} }},')
    w("};")
    w("")
    w("// Section 6.")
    w("inline constexpr ClassPool kClasses[] =")
    w("{")
    for c in model["classes"]:
        traits = ", ".join(f'"{t}"' for t in c["traits"])
        w(f'    {{ "{c["key"]}", {{ {traits} }} }},')
    w("};")
    w("")
    w("// Section 7. skillId 0 means the id is still pending the local check in")
    w("// section 14 item 4; such a profession can only be matched by key.")
    w("inline constexpr ProfessionPool kProfessions[] =")
    w("{")
    for p in model["professions"]:
        traits = ", ".join(f'"{t}"' for t in p["traits"])
        enabled = "true" if p["enabled"] else "false"
        w(f'    {{ "{p["key"]}", {p["skill_id"]}, {enabled}, {{ {traits} }} }},')
    w("};")
    w("")
    w("// Section 9.2. These may never both survive in a finished profile.")
    w("inline constexpr ConflictPair kConflicts[] =")
    w("{")
    for c in model["conflicts"]:
        w(f'    {{ "{c["a"]}", "{c["b"]}" }},')
    w("};")
    w("")
    w("// Every key section 8 defines, so a pool typo fails a test rather than")
    w("// silently producing a trait no prompt builder can resolve.")
    w("inline constexpr char const* kTraitKeys[] =")
    w("{")
    for t in model["traits"]:
        w(f'    "{t["key"]}",')
    w("};")
    w("")
    w("template <typename T, std::size_t N>")
    w("constexpr std::size_t Count(T const (&)[N]) { return N; }")
    w("}   // namespace ai::personality::catalog")
    w("")
    return "\n".join(o)


def write(path, content, check, changed):
    existing = path.read_text(encoding="utf-8") if path.exists() else None
    if existing == content:
        return
    if check:
        changed.append(str(path.relative_to(REPO_ROOT)).replace("\\", "/"))
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    print(f"wrote {path.relative_to(REPO_ROOT)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="do not write; exit 1 if a generated file is stale")
    args = ap.parse_args()

    model = parse(read_contract())
    validate(model)

    changed = []
    traits_json = json.dumps(build_traits_json(model), ensure_ascii=False, indent=2) + "\n"
    write(TRAITS_JSON, traits_json, args.check, changed)
    write(TRAITS_JSON_GO, traits_json, args.check, changed)
    write(POOLS_JSON, json.dumps(build_pools_json(model), ensure_ascii=False, indent=2) + "\n",
          args.check, changed)
    write(CATALOG_H, build_catalog_header(model), args.check, changed)

    print(f"traits: {len(model['traits'])}")
    print(f"races: {len(model['races'])}  variants: {len(model['race_variants'])}  "
          f"classes: {len(model['classes'])}  professions: {len(model['professions'])} "
          f"({sum(1 for p in model['professions'] if p['enabled'])} enabled)")
    print(f"conflicts: {len(model['conflicts'])}")

    if changed:
        print("STALE (re-run without --check):\n  " + "\n  ".join(changed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
