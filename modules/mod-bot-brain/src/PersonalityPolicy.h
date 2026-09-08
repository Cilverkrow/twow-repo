/*
 * mod-bot-brain -- deterministic personality profile selection.
 *
 * Section 4.1, 5, 5.1, 6, 7 and 9 of
 * docs/contracts/personality-context-contract-v1.md, as a pure function.
 *
 * Decision-only, on purpose. No Player, no PlayerbotAI, no database handle, no
 * include from the game: the input is a normalised identity (race key, class
 * key, optional variant key, profession skill ids) and the output is the chosen
 * trait keys with their strengths and origins. Everything that needs a world --
 * reading the identity off a bot, writing the result to `ai_bot_traits` --
 * belongs to the caller. Same split, and the same reason, as
 * core/modules/mod-playerbots/src/playerbot/ProfessionPair.h: a policy that
 * needs a live server to exercise is a policy nobody exercises.
 *
 * The pools themselves are generated, not written here: see
 * PersonalityCatalog.h and ops/contracts/extract-personality-catalog.py.
 *
 * SHA-256 lives in this header rather than coming from OpenSSL. OpenSSL is
 * linked into the worldserver and would have been the reuse-first choice, but
 * it reaches this file only through a target the unit suite does not have --
 * the suite compiles a handful of sources with `dep/include` on the path and
 * links nothing -- and dragging a crypto library into a pure decision test to
 * hash five short strings buys a platform-dependent link for no behaviour. The
 * implementation below is the FIPS 180-4 reference construction and the test
 * suite pins it against the published vectors, so a wrong one fails loudly
 * rather than quietly producing a different-but-stable profile.
 */

#pragma once

#include "PersonalityCatalog.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace ai::personality
{
// Section 4.1 hashes the profile version into every candidate, so a bump here
// re-rolls every bot deliberately (section 4.2).
inline constexpr std::uint32_t kProfileVersion = 1;

// Declaration order IS the section 9.2 priority order, best first:
//   gesperrtes manuelles Trait > Rassenvariante > Klasse > Rasse > Beruf
enum class SourceType : std::uint8_t
{
    Manual = 0,
    RaceVariant = 1,
    Class = 2,
    Race = 3,
    Profession = 4
};

inline char const* SourceTypeName(SourceType type)
{
    switch (type)
    {
        case SourceType::Manual:      return "manual";
        case SourceType::RaceVariant: return "race_variant";
        case SourceType::Class:       return "class";
        case SourceType::Race:        return "race";
        case SourceType::Profession:  return "profession";
    }
    return "unknown";
}

struct Origin
{
    SourceType type;
    std::string key;   // race/class/variant/profession key this origin came from
};

struct Trait
{
    std::string key;
    int strength = 0;
    std::vector<Origin> origins;   // section 9.1: every matching origin is kept
};

// A configured individual trait (section 4, last row). `locked` marks the one
// the contract lets an operator pin: it never loses a conflict and is never
// replaced, because there is no pool to replace it from.
struct ManualTrait
{
    std::string key;
    int strength = catalog::kManualStrength;
    bool locked = false;
};

struct Request
{
    std::uint32_t profileVersion = kProfileVersion;

    // The stable per-bot seed. In this tree that is the bot UUID minted by
    // BotBrainPipeline (ADR-0039), not the GUID: the GUID is a realm-local
    // integer and two realms would otherwise generate identical bots.
    std::string profileSeed;

    std::string race;          // catalog key, e.g. "dwarf"
    std::string cls;           // catalog key, e.g. "warrior"
    std::string raceVariant;   // catalog key or empty; ignored on a mismatched base race

    // Actually learned professions. Skill ids are matched first; the key list
    // exists because section 14 leaves some Turtle professions without a
    // verified id (they carry skillId 0 in the catalog and can only be named).
    std::vector<std::uint32_t> professionSkillIds;
    std::vector<std::string> professionKeys;

    std::vector<ManualTrait> manual;
};

struct Profile
{
    std::vector<Trait> traits;      // sorted by key, so the output is comparable
    bool raceKnown = false;
    bool classKnown = false;
    bool variantApplied = false;    // a recognised variant actually contributed
};

namespace detail
{
    struct Digest
    {
        std::uint8_t bytes[32];
    };

    inline std::uint32_t Rotr(std::uint32_t value, int bits)
    {
        return (value >> bits) | (value << (32 - bits));
    }

    // FIPS 180-4 SHA-256. See the file header for why it is here.
    inline Digest Sha256(std::string const& message)
    {
        static constexpr std::uint32_t kRound[64] = {
            0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
            0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
            0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
            0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
            0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
            0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
            0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
            0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
            0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
            0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
            0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
            0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
            0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
            0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
            0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
            0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
        };

        std::uint32_t h[8] = {
            0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
            0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
        };

        std::vector<std::uint8_t> data(message.begin(), message.end());
        std::uint64_t const bitLength = static_cast<std::uint64_t>(data.size()) * 8u;
        data.push_back(0x80u);
        while (data.size() % 64u != 56u)
            data.push_back(0x00u);
        for (int i = 7; i >= 0; --i)
            data.push_back(static_cast<std::uint8_t>((bitLength >> (i * 8)) & 0xffu));

        for (std::size_t offset = 0; offset < data.size(); offset += 64)
        {
            std::uint32_t w[64];
            for (int i = 0; i < 16; ++i)
            {
                std::size_t const at = offset + static_cast<std::size_t>(i) * 4u;
                w[i] = (static_cast<std::uint32_t>(data[at]) << 24)
                     | (static_cast<std::uint32_t>(data[at + 1]) << 16)
                     | (static_cast<std::uint32_t>(data[at + 2]) << 8)
                     | (static_cast<std::uint32_t>(data[at + 3]));
            }
            for (int i = 16; i < 64; ++i)
            {
                std::uint32_t const s0 = Rotr(w[i - 15], 7) ^ Rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
                std::uint32_t const s1 = Rotr(w[i - 2], 17) ^ Rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16] + s0 + w[i - 7] + s1;
            }

            std::uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
            std::uint32_t e = h[4], f = h[5], g = h[6], hh = h[7];

            for (int i = 0; i < 64; ++i)
            {
                std::uint32_t const s1 = Rotr(e, 6) ^ Rotr(e, 11) ^ Rotr(e, 25);
                std::uint32_t const ch = (e & f) ^ (~e & g);
                std::uint32_t const t1 = hh + s1 + ch + kRound[i] + w[i];
                std::uint32_t const s0 = Rotr(a, 2) ^ Rotr(a, 13) ^ Rotr(a, 22);
                std::uint32_t const maj = (a & b) ^ (a & c) ^ (b & c);
                std::uint32_t const t2 = s0 + maj;

                hh = g; g = f; f = e; e = d + t1;
                d = c; c = b; b = a; a = t1 + t2;
            }

            h[0] += a; h[1] += b; h[2] += c; h[3] += d;
            h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
        }

        Digest digest{};
        for (int i = 0; i < 8; ++i)
        {
            digest.bytes[i * 4]     = static_cast<std::uint8_t>(h[i] >> 24);
            digest.bytes[i * 4 + 1] = static_cast<std::uint8_t>(h[i] >> 16);
            digest.bytes[i * 4 + 2] = static_cast<std::uint8_t>(h[i] >> 8);
            digest.bytes[i * 4 + 3] = static_cast<std::uint8_t>(h[i]);
        }
        return digest;
    }

    inline std::string Sha256Hex(std::string const& message)
    {
        static char const* kHex = "0123456789abcdef";
        Digest const digest = Sha256(message);
        std::string out;
        out.reserve(64);
        for (std::uint8_t byte : digest.bytes)
        {
            out.push_back(kHex[byte >> 4]);
            out.push_back(kHex[byte & 0x0fu]);
        }
        return out;
    }

    inline std::string Decimal(std::uint32_t value)
    {
        if (value == 0)
            return "0";
        std::string out;
        while (value != 0)
        {
            out.push_back(static_cast<char>('0' + (value % 10)));
            value /= 10;
        }
        std::reverse(out.begin(), out.end());
        return out;
    }

    // Section 4.1, verbatim:
    //   SHA-256(profile_version | profile_seed | source_type | source_key | trait_key)
    // The separator is the literal '|' the contract writes. Spelling it out
    // matters more than it looks: any other joiner still produces a stable
    // profile, just not the one another implementation of this contract would.
    inline Digest StableValue(std::uint32_t profileVersion, std::string const& seed,
                              SourceType type, std::string const& sourceKey,
                              std::string const& traitKey)
    {
        std::string material;
        material.reserve(seed.size() + sourceKey.size() + traitKey.size() + 32);
        material += Decimal(profileVersion);
        material += '|';
        material += seed;
        material += '|';
        material += SourceTypeName(type);
        material += '|';
        material += sourceKey;
        material += '|';
        material += traitKey;
        return Sha256(material);
    }

    inline bool Higher(Digest const& lhs, Digest const& rhs)
    {
        return std::memcmp(lhs.bytes, rhs.bytes, sizeof(lhs.bytes)) > 0;
    }

    // One source's draw from one pool: what it may pick, and what it did pick.
    // Modelled explicitly because section 9.2 needs it -- the losing SOURCE
    // draws a conflict-free replacement "damit ihre Quote erhalten bleibt", so
    // resolution has to know which pool a surviving trait came out of.
    struct Draw
    {
        SourceType type = SourceType::Race;
        std::string key;
        int strength = 0;
        std::size_t quota = 0;
        std::vector<std::string> ranked;   // whole pool, best stable value first
        std::vector<std::string> chosen;
    };

    inline std::vector<std::string> RankPool(Request const& request, SourceType type,
                                             std::string const& sourceKey,
                                             std::vector<std::string> const& pool)
    {
        struct Scored
        {
            std::string key;
            Digest value;
        };

        std::vector<Scored> scored;
        scored.reserve(pool.size());
        for (std::string const& key : pool)
            scored.push_back({ key, StableValue(request.profileVersion, request.profileSeed, type, sourceKey, key) });

        // Descending stable value. The trait key breaks a tie so the order is
        // total even in the impossible case of a SHA-256 collision -- a sort
        // with a non-strict comparator is undefined behaviour, not a coin flip.
        std::sort(scored.begin(), scored.end(), [](Scored const& a, Scored const& b) {
            if (std::memcmp(a.value.bytes, b.value.bytes, sizeof(a.value.bytes)) != 0)
                return Higher(a.value, b.value);
            return a.key < b.key;
        });

        std::vector<std::string> ranked;
        ranked.reserve(scored.size());
        for (Scored const& entry : scored)
            ranked.push_back(entry.key);
        return ranked;
    }

    inline catalog::RacePool const* FindRace(std::string const& key)
    {
        for (catalog::RacePool const& pool : catalog::kRaces)
            if (key == pool.key)
                return &pool;
        return nullptr;
    }

    inline catalog::VariantPool const* FindVariant(std::string const& key)
    {
        for (catalog::VariantPool const& pool : catalog::kRaceVariants)
            if (key == pool.key)
                return &pool;
        return nullptr;
    }

    inline catalog::ClassPool const* FindClass(std::string const& key)
    {
        for (catalog::ClassPool const& pool : catalog::kClasses)
            if (key == pool.key)
                return &pool;
        return nullptr;
    }

    inline catalog::ProfessionPool const* FindProfessionBySkill(std::uint32_t skillId)
    {
        if (skillId == 0)
            return nullptr;   // 0 is the catalog's "unverified", not a wildcard
        for (catalog::ProfessionPool const& pool : catalog::kProfessions)
            if (pool.skillId == skillId)
                return &pool;
        return nullptr;
    }

    inline catalog::ProfessionPool const* FindProfessionByKey(std::string const& key)
    {
        for (catalog::ProfessionPool const& pool : catalog::kProfessions)
            if (key == pool.key)
                return &pool;
        return nullptr;
    }

    template <std::size_t N>
    std::vector<std::string> ToVector(char const* const (&traits)[N])
    {
        return std::vector<std::string>(traits, traits + N);
    }

    inline bool Conflicts(std::string const& lhs, std::string const& rhs)
    {
        for (catalog::ConflictPair const& pair : catalog::kConflicts)
        {
            if ((lhs == pair.a && rhs == pair.b) || (lhs == pair.b && rhs == pair.a))
                return true;
        }
        return false;
    }
}   // namespace detail

// The whole policy. Deterministic in its arguments and nothing else.
inline Profile BuildProfile(Request const& request)
{
    using namespace detail;

    Profile profile;
    std::vector<Draw> draws;

    // --- Section 5 and 5.1: race, then the variant that may displace one. ---
    catalog::RacePool const* racePool = FindRace(request.race);
    catalog::VariantPool const* variantPool = FindVariant(request.raceVariant);

    // A variant only applies to its own base race. Anything else is a caller
    // bug or a mis-detected model, and section 5.1 gates the variant behind a
    // confident local check -- so the safe reading of an impossible pair is
    // "no variant", not "trust it anyway".
    if (variantPool && (!racePool || request.race != variantPool->baseRace))
        variantPool = nullptr;

    Draw raceDraw;
    Draw variantDraw;

    if (racePool)
    {
        profile.raceKnown = true;
        raceDraw.type = SourceType::Race;
        raceDraw.key = racePool->key;
        raceDraw.strength = catalog::kRaceStrength;
        raceDraw.quota = catalog::kRaceQuota;
        raceDraw.ranked = RankPool(request, SourceType::Race, raceDraw.key, ToVector(racePool->traits));

        if (variantPool)
        {
            variantDraw.type = SourceType::RaceVariant;
            variantDraw.key = variantPool->key;
            variantDraw.strength = catalog::kVariantStrength;
            variantDraw.quota = catalog::kVariantQuota;
            variantDraw.ranked =
                RankPool(request, SourceType::RaceVariant, variantDraw.key, ToVector(variantPool->traits));
            variantDraw.chosen.push_back(variantDraw.ranked.front());
            profile.variantApplied = true;

            // "ersetzt hoechstens 1 Rassen-Trait ... erzeugt keinen vierten".
            // Taking the top two instead of the top three IS the replacement:
            // the trait that drops out is the lowest-ranked of the three, which
            // is the only choice that leaves the surviving two identical to a
            // variant-less bot's first two. Two pools do overlap --
            // `ritual_minded` is in both the troll and the forest-troll pool --
            // and when the variant lands on a trait the race had already picked
            // there is nothing to replace: the race keeps all three and the
            // variant becomes a second origin on one of them (section 9.1).
            auto const raceCut =
                raceDraw.ranked.begin() + static_cast<std::ptrdiff_t>(catalog::kRaceQuota);
            bool const variantAlsoRace =
                std::find(raceDraw.ranked.begin(), raceCut, variantDraw.chosen.front()) != raceCut;
            raceDraw.quota = variantAlsoRace ? catalog::kRaceQuota : catalog::kRaceQuota - 1;
        }

        raceDraw.chosen.assign(raceDraw.ranked.begin(),
                               raceDraw.ranked.begin() + static_cast<std::ptrdiff_t>(raceDraw.quota));
        draws.push_back(raceDraw);
        if (profile.variantApplied)
            draws.push_back(variantDraw);
    }

    // --- Section 6: class. -------------------------------------------------
    if (catalog::ClassPool const* classPool = FindClass(request.cls))
    {
        profile.classKnown = true;
        Draw draw;
        draw.type = SourceType::Class;
        draw.key = classPool->key;
        draw.strength = catalog::kClassStrength;
        draw.quota = catalog::kClassQuota;
        draw.ranked = RankPool(request, SourceType::Class, draw.key, ToVector(classPool->traits));
        draw.chosen.assign(draw.ranked.begin(),
                           draw.ranked.begin() + static_cast<std::ptrdiff_t>(draw.quota));
        draws.push_back(draw);
    }

    // --- Section 7: one trait per actually learned profession. -------------
    std::vector<catalog::ProfessionPool const*> professions;
    auto addProfession = [&professions](catalog::ProfessionPool const* pool) {
        // Section 7 keeps gardening and jewelcrafting deactivated until someone
        // confirms this server has them, so an id or key that reaches one is
        // dropped rather than provisioned.
        if (!pool || !pool->enabled)
            return;
        for (catalog::ProfessionPool const* seen : professions)
            if (seen == pool)
                return;
        professions.push_back(pool);
    };

    for (std::uint32_t skillId : request.professionSkillIds)
        addProfession(FindProfessionBySkill(skillId));
    for (std::string const& key : request.professionKeys)
        addProfession(FindProfessionByKey(key));

    for (catalog::ProfessionPool const* pool : professions)
    {
        Draw draw;
        draw.type = SourceType::Profession;
        draw.key = pool->key;
        draw.strength = catalog::kProfessionStrength;
        draw.quota = catalog::kProfessionQuota;
        draw.ranked = RankPool(request, SourceType::Profession, draw.key, ToVector(pool->traits));
        draw.chosen.assign(draw.ranked.begin(),
                           draw.ranked.begin() + static_cast<std::ptrdiff_t>(draw.quota));
        draws.push_back(draw);
    }

    // --- Section 4: manual traits. -----------------------------------------
    // A one-element pool: it can lose a conflict to another manual trait, but
    // there is nothing to replace it with, so it simply leaves.
    for (ManualTrait const& manual : request.manual)
    {
        if (manual.key.empty())
            continue;
        Draw draw;
        draw.type = SourceType::Manual;
        draw.key = manual.locked ? "locked" : "configured";
        draw.strength = std::min(catalog::kStrengthMax, std::max(catalog::kStrengthMin, manual.strength));
        draw.quota = 1;
        draw.ranked.push_back(manual.key);
        draw.chosen.push_back(manual.key);
        draws.push_back(draw);
    }

    // --- Section 9.2: resolve hard conflicts. ------------------------------
    //
    // Each pass removes one losing trait and, where the losing source has a
    // pool, replaces it with the best-ranked candidate that conflicts with
    // nothing currently held. A replacement is chosen conflict-free against the
    // live selection, so a pass can never introduce a conflict; the number of
    // conflicting pairs therefore strictly falls and the loop terminates. The
    // iteration cap is a guard against a future edit breaking that argument,
    // not something the current rules can reach.
    auto selectionContains = [&draws](std::string const& key) {
        for (Draw const& draw : draws)
            for (std::string const& chosen : draw.chosen)
                if (chosen == key)
                    return true;
        return false;
    };

    // Best (numerically lowest) priority among a trait's origins, plus the
    // strength and stable value that go with it -- section 9.2's tiebreakers.
    auto rank = [&draws, &request](std::string const& key, SourceType& type, int& strength, Digest& value) {
        bool found = false;
        for (Draw const& draw : draws)
        {
            if (std::find(draw.chosen.begin(), draw.chosen.end(), key) == draw.chosen.end())
                continue;
            if (!found || static_cast<std::uint8_t>(draw.type) < static_cast<std::uint8_t>(type)
                || (draw.type == type && draw.strength > strength))
            {
                type = draw.type;
                strength = draw.strength;
                value = StableValue(request.profileVersion, request.profileSeed, draw.type, draw.key, key);
                found = true;
            }
        }
        return found;
    };

    for (std::size_t pass = 0; pass < 64; ++pass)
    {
        std::string loser;

        for (catalog::ConflictPair const& pair : catalog::kConflicts)
        {
            std::string const a = pair.a;
            std::string const b = pair.b;
            if (!selectionContains(a) || !selectionContains(b))
                continue;

            SourceType typeA = SourceType::Profession, typeB = SourceType::Profession;
            int strengthA = 0, strengthB = 0;
            Digest valueA{}, valueB{};
            rank(a, typeA, strengthA, valueA);
            rank(b, typeB, strengthB, valueB);

            bool aWins;
            if (typeA != typeB)
                aWins = static_cast<std::uint8_t>(typeA) < static_cast<std::uint8_t>(typeB);
            else if (strengthA != strengthB)
                aWins = strengthA > strengthB;
            else if (std::memcmp(valueA.bytes, valueB.bytes, sizeof(valueA.bytes)) != 0)
                aWins = Higher(valueA, valueB);
            else
                aWins = a < b;

            // A locked manual trait cannot be dropped (section 4, "kann als
            // gesperrt markiert werden"); it already outranks every other
            // source, so this only bites when two conflicting manual traits are
            // both locked. That is a configuration error, and the policy leaves
            // the conflict standing rather than papering over it by silently
            // deleting one of the operator's own choices.
            std::string const candidate = aWins ? b : a;
            if (std::any_of(request.manual.begin(), request.manual.end(),
                            [&candidate](ManualTrait const& m) { return m.locked && m.key == candidate; }))
                continue;

            loser = candidate;
            break;
        }

        if (loser.empty())
            break;

        for (Draw& draw : draws)
        {
            auto at = std::find(draw.chosen.begin(), draw.chosen.end(), loser);
            if (at == draw.chosen.end())
                continue;
            draw.chosen.erase(at);

            for (std::string const& candidate : draw.ranked)
            {
                if (candidate == loser || selectionContains(candidate))
                    continue;

                bool clean = true;
                for (Draw const& other : draws)
                    for (std::string const& held : other.chosen)
                        if (Conflicts(candidate, held))
                            clean = false;

                if (!clean)
                    continue;

                draw.chosen.push_back(candidate);
                break;
            }
            // No conflict-free candidate left in this pool means the source
            // runs one short. That is the honest outcome: the contract asks for
            // a replacement "aus deren Pool", and inventing one from elsewhere
            // would break the pool boundary it is protecting.
        }
    }

    // --- Section 9.1: merge duplicates, strength is the MAXIMUM. ------------
    for (Draw const& draw : draws)
    {
        for (std::string const& key : draw.chosen)
        {
            int const strength =
                std::min(catalog::kStrengthMax, std::max(catalog::kStrengthMin, draw.strength));

            auto at = std::find_if(profile.traits.begin(), profile.traits.end(),
                                   [&key](Trait const& trait) { return trait.key == key; });
            if (at == profile.traits.end())
            {
                Trait trait;
                trait.key = key;
                trait.strength = strength;
                trait.origins.push_back({ draw.type, draw.key });
                profile.traits.push_back(trait);
                continue;
            }

            at->strength = std::max(at->strength, strength);
            at->origins.push_back({ draw.type, draw.key });
        }
    }

    std::sort(profile.traits.begin(), profile.traits.end(),
              [](Trait const& a, Trait const& b) { return a.key < b.key; });

    return profile;
}

// Convenience for callers and tests: how many of the profile's traits carry an
// origin of this type. Quotas are stated per SOURCE, and a trait shared by two
// sources must count for both.
inline std::size_t CountOrigins(Profile const& profile, SourceType type)
{
    std::size_t count = 0;
    for (Trait const& trait : profile.traits)
        for (Origin const& origin : trait.origins)
            if (origin.type == type)
                ++count;
    return count;
}

inline bool HasTrait(Profile const& profile, std::string const& key)
{
    return std::any_of(profile.traits.begin(), profile.traits.end(),
                       [&key](Trait const& trait) { return trait.key == key; });
}
}   // namespace ai::personality
