/*
 * mod-bot-brain -- the translation between a live character and the personality
 * policy's vocabulary, and the storage form of a finished profile.
 *
 * PersonalityPolicy.h is deliberately a pure function over catalog KEYS
 * ("dwarf", "warrior"), and the worldserver deals in numeric ids
 * (RACE_DWARF, CLASS_WARRIOR) and a comma-separated database column. Something
 * has to sit between them, and this is it -- kept in its own header, free of
 * every game include, for the same reason the policy is: a mapping that needs a
 * running server to exercise is a mapping nobody exercises, and getting one
 * entry of it wrong hands a bot a permanent personality built on the wrong race.
 *
 * The numeric constants below MIRROR core/src/game/SharedDefines.h rather than
 * including it. That duplication is the price of hermeticity, and it is paid
 * back at compile time: BotBrainPipeline.cpp static_asserts every one of them
 * against the real enum, so a core that ever renumbers a race breaks the build
 * instead of silently re-rolling a population.
 *
 * Professions are NOT mapped here. PersonalityCatalog.h already carries each
 * profession's skill id, so the caller matches by id straight out of the
 * catalog and there is no second list to keep in step.
 */

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace ai::personality::identity
{
// Mirrors of SharedDefines.h, asserted against it where the game is available.
enum : std::uint8_t
{
    kRaceHuman    = 1,
    kRaceOrc      = 2,
    kRaceDwarf    = 3,
    kRaceNightElf = 4,
    kRaceUndead   = 5,
    kRaceTauren   = 6,
    kRaceGnome    = 7,
    kRaceTroll    = 8,
    kRaceGoblin   = 9,
    kRaceHighElf  = 10
};

enum : std::uint8_t
{
    kClassWarrior = 1,
    kClassPaladin = 2,
    kClassHunter  = 3,
    kClassRogue   = 4,
    kClassPriest  = 5,
    kClassShaman  = 7,
    kClassMage    = 8,
    kClassWarlock = 9,
    kClassDruid   = 11
};

// The catalog key for a race id, or "" when there is none.
//
// An empty return is a supported answer and not an error: section 5 pools the
// ten playable races, and a character of anything else -- a GM-made oddity, or a
// race a future core adds -- gets no race traits rather than a guessed pool.
// The policy already treats an unknown race that way (Profile::raceKnown), so
// the two halves agree by construction.
inline char const* RaceKey(std::uint8_t race)
{
    switch (race)
    {
        case kRaceHuman:    return "human";
        case kRaceOrc:      return "orc";
        case kRaceDwarf:    return "dwarf";
        case kRaceNightElf: return "night_elf";
        case kRaceUndead:   return "undead";
        case kRaceTauren:   return "tauren";
        case kRaceGnome:    return "gnome";
        case kRaceTroll:    return "troll";
        case kRaceGoblin:   return "goblin";
        case kRaceHighElf:  return "high_elf";
        default:            return "";
    }
}

// The catalog key for a class id, or "" when there is none. Same reading as
// RaceKey: ids 6 and 10 are gaps in the enum on this core, and a character
// somehow holding one gets no class traits rather than a neighbour's pool.
inline char const* ClassKey(std::uint8_t cls)
{
    switch (cls)
    {
        case kClassWarrior: return "warrior";
        case kClassPaladin: return "paladin";
        case kClassHunter:  return "hunter";
        case kClassRogue:   return "rogue";
        case kClassPriest:  return "priest";
        case kClassShaman:  return "shaman";
        case kClassMage:    return "mage";
        case kClassWarlock: return "warlock";
        case kClassDruid:   return "druid";
        default:            return "";
    }
}

// --- The storage form of a finished profile. -------------------------------
//
// cv_brain.bot_personality.trait_keys is one comma-separated ascii list; see
// that migration for why the profile is one row rather than one row per trait.
// The separator is safe by construction rather than by hope: every key in
// PersonalityCatalog.h is [a-z_]+, and kTraitKeys is asserted against the pools,
// so no key can ever contain the separator. Decode still refuses anything that
// looks otherwise -- a column edited by hand is a real possibility, and a trait
// key with a stray space in it must be dropped rather than sent onto the wire
// where nothing downstream can resolve it.

inline std::string EncodeTraitKeys(std::vector<std::string> const& keys)
{
    std::string out;
    for (std::string const& key : keys)
    {
        if (key.empty())
            continue;
        if (!out.empty())
            out.push_back(',');
        out += key;
    }
    return out;
}

// True for the shape every catalog key has. Used as a filter on the way OUT of
// the database, not on the way in: what this module wrote is trusted, what it
// reads back a month later is not necessarily what it wrote.
inline bool IsPlausibleTraitKey(std::string const& key)
{
    if (key.empty() || key.size() > 64)
        return false;
    for (char const c : key)
        if (!((c >= 'a' && c <= 'z') || c == '_'))
            return false;
    return true;
}

inline std::vector<std::string> DecodeTraitKeys(std::string const& stored)
{
    std::vector<std::string> keys;
    std::string current;

    // Deliberately hand-rolled rather than a stringstream: the empty string
    // must yield an empty vector and not a single empty token, and that is the
    // case that actually occurs (a bot whose race and class are both unknown to
    // the catalog has a legitimately empty profile).
    for (std::size_t i = 0; i <= stored.size(); ++i)
    {
        if (i == stored.size() || stored[i] == ',')
        {
            if (IsPlausibleTraitKey(current))
                keys.push_back(current);
            current.clear();
            continue;
        }
        current.push_back(stored[i]);
    }
    return keys;
}
}   // namespace ai::personality::identity
