/*
 * mod-bot-brain -- personality trait pools, section 5/5.1/6/7 of the
 * personality context contract, as ASCII-only C++ tables.
 *
 * GENERATED FILE. Do not edit by hand.
 * Source of truth: docs/contracts/personality-context-contract-v1.md
 * Regenerate:      python ops/contracts/extract-personality-catalog.py
 *
 * Keys only, no German labels and no Ollama instructions: those live in
 * contracts/personality/v1/traits.json and belong to the prompt builder.
 * Keeping this header pure ASCII is what lets the policy layer compile
 * with no encoding flags and no fixture to load.
 */

#pragma once

#include <cstddef>
#include <cstdint>

namespace ai::personality::catalog
{
// Section 4: quotas and default strengths. Strengths clamp to [20, 80].
inline constexpr int kStrengthMin = 20;
inline constexpr int kStrengthMax = 80;
inline constexpr int kRaceStrength = 55;
inline constexpr int kVariantStrength = 60;
inline constexpr int kClassStrength = 65;
inline constexpr int kProfessionStrength = 45;
inline constexpr int kManualStrength = 70;

inline constexpr std::size_t kRaceQuota = 3;
inline constexpr std::size_t kClassQuota = 2;
inline constexpr std::size_t kProfessionQuota = 1;
inline constexpr std::size_t kVariantQuota = 1;

inline constexpr std::size_t kRacePoolSize = 6;
inline constexpr std::size_t kVariantPoolSize = 6;
inline constexpr std::size_t kClassPoolSize = 5;
inline constexpr std::size_t kProfessionPoolSize = 3;

struct RacePool
{
    char const* key;
    char const* traits[kRacePoolSize];
};

struct VariantPool
{
    char const* key;
    char const* baseRace;   // the variant is ignored on any other race
    char const* traits[kVariantPoolSize];
};

struct ClassPool
{
    char const* key;
    char const* traits[kClassPoolSize];
};

struct ProfessionPool
{
    char const* key;
    std::uint32_t skillId;   // 0 = not verified against this server yet
    bool enabled;            // section 7's deactivated candidates are false
    char const* traits[kProfessionPoolSize];
};

struct ConflictPair
{
    char const* a;
    char const* b;
};

// Section 5.
inline constexpr RacePool kRaces[] =
{
    { "human", { "adaptable", "ambitious", "diplomatic", "dutiful", "curious", "sociable" } },
    { "dwarf", { "stubborn", "traditionalist", "loyal", "craft_proud", "dry_humor", "feast_loving" } },
    { "gnome", { "quirky", "inventive", "curious", "optimistic", "talkative", "absent_minded" } },
    { "night_elf", { "reserved", "nature_bound", "vigilant", "patient", "spiritual", "ancient_minded" } },
    { "high_elf", { "proud", "refined", "formal", "perfectionist", "arcane_minded", "melancholic" } },
    { "orc", { "honor_bound", "direct", "passionate", "tenacious", "competitive", "clan_loyal" } },
    { "tauren", { "calm", "protective", "spiritual", "patient", "communal", "nature_bound" } },
    { "troll", { "cunning", "playful", "superstitious", "adaptable", "relaxed", "ritual_minded" } },
    { "undead", { "mysterious", "skeptical", "resilient", "distant", "indirect", "dark_humor" } },
    { "goblin", { "business_minded", "fast_talking", "inventive", "opportunistic", "risk_taking", "practical" } },
};

// Section 5.1.
inline constexpr VariantPool kRaceVariants[] =
{
    { "blood_elf", "high_elf", { "defiant", "arcane_dependent", "wounded_pride", "ambitious", "elegant", "pragmatic" } },
    { "dark_iron", "dwarf", { "suspicious", "fiery_temper", "forge_bound", "clan_loyal", "resilient", "secretive" } },
    { "wildhammer", "dwarf", { "free_spirited", "gryphon_loving", "storm_minded", "outdoorsy", "boisterous", "clan_loyal" } },
    { "forest", "troll", { "tribal", "wilderness_savvy", "fierce", "ritual_minded", "wary", "tenacious" } },
};

// Section 6.
inline constexpr ClassPool kClasses[] =
{
    { "warrior", { "proud", "protective", "direct", "disciplined", "battle_eager" } },
    { "rogue", { "discreet", "charming", "mistrustful", "opportunistic", "witty" } },
    { "hunter", { "patient", "observant", "animal_friendly", "independent", "tracker_minded" } },
    { "mage", { "scholarly", "curious", "analytical", "self_confident", "absent_minded" } },
    { "warlock", { "secretive", "power_minded", "pragmatic", "controlled", "dark_humor" } },
    { "druid", { "nature_bound", "calm", "empathetic", "changeable", "reserved" } },
    { "shaman", { "spirit_minded", "traditionalist", "communal", "balanced", "passionate" } },
    { "priest", { "faithful", "compassionate", "pastoral", "contemplative", "zealous" } },
    { "paladin", { "faithful", "protective", "righteous", "disciplined", "uncompromising" } },
};

// Section 7. skillId 0 means the id is still pending the local check in
// section 14 item 4; such a profession can only be matched by key.
inline constexpr ProfessionPool kProfessions[] =
{
    { "alchemy", 171, true, { "experimental", "precise", "ingredient_minded" } },
    { "blacksmithing", 164, true, { "craft_proud", "quality_minded", "direct" } },
    { "enchanting", 333, true, { "meticulous", "mystical", "perfectionist" } },
    { "engineering", 202, true, { "inventive", "chaotic", "solution_oriented" } },
    { "herbalism", 182, true, { "observant", "patient", "plant_minded" } },
    { "leatherworking", 165, true, { "practical", "material_minded", "resourceful" } },
    { "mining", 186, true, { "tenacious", "ore_minded", "underground_comfortable" } },
    { "skinning", 393, true, { "pragmatic", "fearless", "resource_conscious" } },
    { "tailoring", 197, true, { "aesthetic", "meticulous", "status_conscious" } },
    { "cooking", 185, true, { "hospitable", "taste_minded", "storyteller" } },
    { "fishing", 356, true, { "patient", "calm", "tall_tale_teller" } },
    { "first_aid", 129, true, { "helpful", "calm", "practical" } },
    { "survival", 0, true, { "prepared", "adaptable", "wilderness_savvy" } },
    { "gardening", 0, false, { "patient", "nurturing", "seasonal_minded" } },
    { "jewelcrafting", 0, false, { "precise", "aesthetic", "gem_minded" } },
};

// Section 9.2. These may never both survive in a finished profile.
inline constexpr ConflictPair kConflicts[] =
{
    { "talkative", "reserved" },
    { "direct", "indirect" },
    { "calm", "fiery_temper" },
    { "disciplined", "chaotic" },
    { "sociable", "distant" },
    { "wary", "risk_taking" },
};

// Every key section 8 defines, so a pool typo fails a test rather than
// silently producing a trait no prompt builder can resolve.
inline constexpr char const* kTraitKeys[] =
{
    "adaptable",
    "ambitious",
    "diplomatic",
    "dutiful",
    "curious",
    "sociable",
    "stubborn",
    "traditionalist",
    "loyal",
    "dry_humor",
    "feast_loving",
    "quirky",
    "optimistic",
    "talkative",
    "absent_minded",
    "reserved",
    "patient",
    "proud",
    "refined",
    "formal",
    "melancholic",
    "direct",
    "passionate",
    "tenacious",
    "competitive",
    "clan_loyal",
    "calm",
    "protective",
    "communal",
    "cunning",
    "playful",
    "superstitious",
    "relaxed",
    "mysterious",
    "skeptical",
    "resilient",
    "distant",
    "indirect",
    "dark_humor",
    "business_minded",
    "fast_talking",
    "opportunistic",
    "risk_taking",
    "practical",
    "nature_bound",
    "vigilant",
    "spiritual",
    "ancient_minded",
    "arcane_minded",
    "honor_bound",
    "ritual_minded",
    "disciplined",
    "battle_eager",
    "discreet",
    "charming",
    "mistrustful",
    "witty",
    "observant",
    "animal_friendly",
    "independent",
    "tracker_minded",
    "scholarly",
    "analytical",
    "self_confident",
    "secretive",
    "power_minded",
    "pragmatic",
    "controlled",
    "empathetic",
    "changeable",
    "spirit_minded",
    "balanced",
    "faithful",
    "compassionate",
    "pastoral",
    "contemplative",
    "zealous",
    "righteous",
    "uncompromising",
    "craft_proud",
    "inventive",
    "experimental",
    "precise",
    "ingredient_minded",
    "quality_minded",
    "meticulous",
    "mystical",
    "perfectionist",
    "chaotic",
    "solution_oriented",
    "plant_minded",
    "material_minded",
    "resourceful",
    "ore_minded",
    "underground_comfortable",
    "resource_conscious",
    "fearless",
    "aesthetic",
    "status_conscious",
    "hospitable",
    "taste_minded",
    "storyteller",
    "tall_tale_teller",
    "helpful",
    "prepared",
    "wilderness_savvy",
    "nurturing",
    "seasonal_minded",
    "gem_minded",
    "defiant",
    "arcane_dependent",
    "wounded_pride",
    "elegant",
    "suspicious",
    "fiery_temper",
    "forge_bound",
    "free_spirited",
    "gryphon_loving",
    "storm_minded",
    "outdoorsy",
    "boisterous",
    "tribal",
    "fierce",
    "wary",
};

template <typename T, std::size_t N>
constexpr std::size_t Count(T const (&)[N]) { return N; }
}   // namespace ai::personality::catalog
