/*
 * mod-bot-brain -- unit tests for deterministic personality selection.
 *
 * Hand-rolled assertions and one plain main(), the same shape as
 * bot_brain_wire_tests.cpp beside it and
 * core/modules/mod-playerbots/t/profession_pair_policy_tests.cpp: no framework
 * to fetch, and the suite stays compilable in the default configuration.
 *
 * These are property tests, deliberately, and they sweep seeds rather than
 * pinning one profile. The acceptance criteria in section 16 of the contract
 * are all universally quantified -- "duplicates and hard conflicts are resolved
 * reproducibly", "two bots of the same race and class stay distinguishable" --
 * and a single golden profile proves none of them. It would also be the one
 * assertion that goes red for a harmless re-ordering.
 *
 * The one thing pinned to exact bytes is SHA-256 itself, against the FIPS
 * 180-4 published vectors. That implementation is what makes every profile in
 * this system stable, and a subtly wrong one would still produce
 * stable-looking output -- just not the output any other implementation of
 * this contract would agree with.
 *
 * Run with `--dump-profile` and the binary prints one sample profile as JSON
 * instead of running the suite. That is how a golden fixture gets captured for
 * the DB/bridge side once the C++ has actually run somewhere.
 */

#include "PersonalityPolicy.h"

#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace
{
    using namespace ai::personality;

    int g_failures = 0;
    int g_checks = 0;

    void Check(bool condition, char const* what, int line)
    {
        ++g_checks;
        if (condition)
            return;
        ++g_failures;
        std::printf("FAIL line %d: %s\n", line, what);
    }

#define CHECK(cond) Check((cond), #cond, __LINE__)

    // A spread of v4-shaped UUIDs, which is what BotBrainPipeline actually
    // mints for a bot. Only the last field varies: seeds that differ in one
    // character are the hard case for any "stable value" that is not a real
    // hash.
    std::string Seed(int index)
    {
        char buffer[64];
        std::snprintf(buffer, sizeof(buffer), "1af0c9d1-0000-4000-8000-%012d", index);
        return buffer;
    }

    std::vector<std::string> AllRaces()
    {
        std::vector<std::string> keys;
        for (catalog::RacePool const& pool : catalog::kRaces)
            keys.push_back(pool.key);
        return keys;
    }

    std::vector<std::string> AllClasses()
    {
        std::vector<std::string> keys;
        for (catalog::ClassPool const& pool : catalog::kClasses)
            keys.push_back(pool.key);
        return keys;
    }

    std::string Flatten(Profile const& profile)
    {
        std::string out;
        for (Trait const& trait : profile.traits)
        {
            out += trait.key;
            out += ':';
            out += std::to_string(trait.strength);
            out += ';';
        }
        return out;
    }

    std::size_t CountOriginsFrom(Profile const& profile, SourceType type, std::string const& key)
    {
        std::size_t count = 0;
        for (Trait const& trait : profile.traits)
            for (Origin const& origin : trait.origins)
                if (origin.type == type && origin.key == key)
                    ++count;
        return count;
    }

    // Distinct traits carrying a race OR variant origin. The quota that matters
    // in section 5.1 is this one: the variant replaces, it does not extend.
    std::size_t RaceFamilySize(Profile const& profile)
    {
        std::size_t count = 0;
        for (Trait const& trait : profile.traits)
        {
            bool fromRace = false;
            for (Origin const& origin : trait.origins)
                if (origin.type == SourceType::Race || origin.type == SourceType::RaceVariant)
                    fromRace = true;
            if (fromRace)
                ++count;
        }
        return count;
    }

    bool HoldsAConflict(Profile const& profile, std::string& a, std::string& b)
    {
        for (catalog::ConflictPair const& pair : catalog::kConflicts)
        {
            if (HasTrait(profile, pair.a) && HasTrait(profile, pair.b))
            {
                a = pair.a;
                b = pair.b;
                return true;
            }
        }
        return false;
    }

    Request MakeRequest(std::string const& seed, std::string const& race, std::string const& cls)
    {
        Request request;
        request.profileSeed = seed;
        request.race = race;
        request.cls = cls;
        return request;
    }

    // ---------------------------------------------------------------------

    void TestSha256MatchesThePublishedVectors()
    {
        CHECK(detail::Sha256Hex("") ==
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        CHECK(detail::Sha256Hex("abc") ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        // Two blocks, so a broken length-append or message schedule shows up.
        CHECK(detail::Sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    }

    void TestStableValueIsTheContractFormula()
    {
        // Section 4.1 spells the input out; this is the assertion that keeps a
        // future refactor from changing the joiner and silently re-rolling
        // every bot on the server.
        detail::Digest const value =
            detail::StableValue(1, "seed", SourceType::Race, "dwarf", "stubborn");

        std::string hex;
        static char const* kHex = "0123456789abcdef";
        for (std::uint8_t byte : value.bytes)
        {
            hex.push_back(kHex[byte >> 4]);
            hex.push_back(kHex[byte & 0x0fu]);
        }

        CHECK(hex == detail::Sha256Hex("1|seed|race|dwarf|stubborn"));
        CHECK(hex == "2f967b73d68214cf1228b99703f5b2a266b9a1be04c8af9ffe7b9760a327bed8");
    }

    void TestCatalogIsWellFormed()
    {
        std::set<std::string> known;
        for (char const* key : catalog::kTraitKeys)
            known.insert(key);

        CHECK(known.size() == catalog::Count(catalog::kTraitKeys));   // no duplicate keys
        CHECK(catalog::Count(catalog::kRaces) == 10);
        CHECK(catalog::Count(catalog::kRaceVariants) == 4);
        CHECK(catalog::Count(catalog::kClasses) == 9);
        CHECK(catalog::Count(catalog::kConflicts) == 6);

        // A pool key with no section 8 entry would reach the prompt builder as
        // a trait with no instruction, which is exactly the failure that stays
        // invisible until a bot says something bland in production.
        for (catalog::RacePool const& pool : catalog::kRaces)
            for (char const* key : pool.traits)
                CHECK(known.count(key) == 1);
        for (catalog::VariantPool const& pool : catalog::kRaceVariants)
            for (char const* key : pool.traits)
                CHECK(known.count(key) == 1);
        for (catalog::ClassPool const& pool : catalog::kClasses)
            for (char const* key : pool.traits)
                CHECK(known.count(key) == 1);
        for (catalog::ProfessionPool const& pool : catalog::kProfessions)
            for (char const* key : pool.traits)
                CHECK(known.count(key) == 1);
        for (catalog::ConflictPair const& pair : catalog::kConflicts)
        {
            CHECK(known.count(pair.a) == 1);
            CHECK(known.count(pair.b) == 1);
        }

        // Section 4's numbers, so a mis-transcribed strength fails here rather
        // than shipping a whole realm of slightly-wrong bots.
        CHECK(catalog::kRaceStrength == 55);
        CHECK(catalog::kVariantStrength == 60);
        CHECK(catalog::kClassStrength == 65);
        CHECK(catalog::kProfessionStrength == 45);
        CHECK(catalog::kManualStrength == 70);
        CHECK(catalog::kStrengthMin == 20);
        CHECK(catalog::kStrengthMax == 80);
    }

    void TestDeterminism()
    {
        Request request = MakeRequest(Seed(7), "dwarf", "warrior");
        request.professionSkillIds = { 186, 164 };   // mining, blacksmithing

        CHECK(Flatten(BuildProfile(request)) == Flatten(BuildProfile(request)));

        // Same bot, different seed: section 16 requires two bots of the same
        // race and class to stay distinguishable, so this must almost always
        // differ. Counted across many seeds rather than asserted on one pair,
        // because one pair colliding is legitimate and would be flaky.
        std::set<std::string> distinct;
        for (int i = 0; i < 200; ++i)
        {
            Request other = request;
            other.profileSeed = Seed(i);
            distinct.insert(Flatten(BuildProfile(other)));
        }
        CHECK(distinct.size() > 50);

        // Bumping the profile version re-rolls deliberately (section 4.2).
        Request bumped = request;
        bumped.profileVersion = 2;
        CHECK(Flatten(BuildProfile(bumped)) != Flatten(BuildProfile(request)));
    }

    void TestQuotasAndConflictsAcrossManySeeds()
    {
        std::vector<std::vector<std::uint32_t>> const professionSets = {
            {},
            { 186 },                       // mining
            { 186, 164 },                  // mining + blacksmithing
            { 202, 182, 356 },             // engineering + herbalism + fishing
            { 171, 182, 185, 129 }         // alchemy + herbalism + cooking + first aid
        };

        std::size_t profiles = 0;
        std::size_t conflictsFound = 0;

        for (int seedIndex = 0; seedIndex < 40; ++seedIndex)
        {
            for (std::string const& race : AllRaces())
            {
                for (std::string const& cls : AllClasses())
                {
                    for (std::vector<std::uint32_t> const& professions : professionSets)
                    {
                        Request request = MakeRequest(Seed(seedIndex), race, cls);
                        request.professionSkillIds = professions;
                        Profile const profile = BuildProfile(request);
                        ++profiles;

                        // Section 4 quotas, exactly -- not "at most".
                        CHECK(CountOrigins(profile, SourceType::Race) == 3);
                        CHECK(CountOrigins(profile, SourceType::Class) == 2);
                        CHECK(RaceFamilySize(profile) == 3);

                        for (std::uint32_t skill : professions)
                        {
                            catalog::ProfessionPool const* pool = detail::FindProfessionBySkill(skill);
                            CHECK(pool != nullptr);
                            if (pool)
                                CHECK(CountOriginsFrom(profile, SourceType::Profession, pool->key) == 1);
                        }

                        // Section 9.2: no hard conflict may survive.
                        std::string a, b;
                        if (HoldsAConflict(profile, a, b))
                        {
                            ++conflictsFound;
                            if (conflictsFound < 5)
                                std::printf("  conflict survived: seed=%s race=%s class=%s %s+%s\n",
                                            Seed(seedIndex).c_str(), race.c_str(), cls.c_str(),
                                            a.c_str(), b.c_str());
                        }

                        for (Trait const& trait : profile.traits)
                        {
                            CHECK(trait.strength >= catalog::kStrengthMin);
                            CHECK(trait.strength <= catalog::kStrengthMax);
                            CHECK(!trait.origins.empty());
                        }
                    }
                }
            }
        }

        CHECK(conflictsFound == 0);
        CHECK(profiles == 40u * 10u * 9u * 5u);
    }

    void TestConflictResolutionActuallyFires()
    {
        // A test that never exercises the resolver would pass the assertion
        // above for the wrong reason. An undead warrior draws `indirect` from
        // the race pool and `direct` from the class pool often enough that some
        // seed in this range hits it; when it does, the class keeps its trait
        // (higher priority) and the race still ends up with three.
        std::size_t resolved = 0;

        for (int seedIndex = 0; seedIndex < 200; ++seedIndex)
        {
            Request const request = MakeRequest(Seed(seedIndex), "undead", "warrior");

            std::vector<std::string> const racePool =
                detail::ToVector(detail::FindRace("undead")->traits);
            std::vector<std::string> const raceRanked =
                detail::RankPool(request, SourceType::Race, "undead", racePool);
            std::vector<std::string> const classPool =
                detail::ToVector(detail::FindClass("warrior")->traits);
            std::vector<std::string> const classRanked =
                detail::RankPool(request, SourceType::Class, "warrior", classPool);

            bool const raceWantsIndirect =
                raceRanked[0] == "indirect" || raceRanked[1] == "indirect" || raceRanked[2] == "indirect";
            bool const classWantsDirect = classRanked[0] == "direct" || classRanked[1] == "direct";
            if (!raceWantsIndirect || !classWantsDirect)
                continue;

            ++resolved;
            Profile const profile = BuildProfile(request);
            CHECK(HasTrait(profile, "direct"));      // class outranks race
            CHECK(!HasTrait(profile, "indirect"));
            CHECK(CountOrigins(profile, SourceType::Race) == 3);   // the quota survived
            CHECK(CountOrigins(profile, SourceType::Class) == 2);
        }

        CHECK(resolved > 0);
    }

    void TestVariantReplacesAtMostOneRaceTrait()
    {
        for (catalog::VariantPool const& variant : catalog::kRaceVariants)
        {
            std::size_t coincidences = 0;

            for (int seedIndex = 0; seedIndex < 60; ++seedIndex)
            {
                Request request = MakeRequest(Seed(seedIndex), variant.baseRace, "warrior");
                request.raceVariant = variant.key;
                Profile const profile = BuildProfile(request);

                CHECK(profile.variantApplied);
                CHECK(CountOrigins(profile, SourceType::RaceVariant) == 1);

                // Never a fourth: exactly three traits carry a race-family
                // origin, whether or not the variant landed on one the base
                // race had already picked.
                CHECK(RaceFamilySize(profile) == 3);

                std::size_t const raceOrigins = CountOrigins(profile, SourceType::Race);
                CHECK(raceOrigins == 2 || raceOrigins == 3);
                if (raceOrigins == 3)
                    ++coincidences;   // the variant trait is also in the base pool
            }

            // Without a variant the base race keeps all three of its own.
            Request plain = MakeRequest(Seed(3), variant.baseRace, "warrior");
            Profile const plainProfile = BuildProfile(plain);
            CHECK(!plainProfile.variantApplied);
            CHECK(CountOrigins(plainProfile, SourceType::Race) == 3);
            CHECK(RaceFamilySize(plainProfile) == 3);

            (void)coincidences;
        }
    }

    void TestVariantOnTheWrongRaceIsIgnored()
    {
        // Section 5.1 gates a variant behind a confident local check. An
        // impossible pair is a detection bug, and trusting it anyway would hand
        // a human a dwarf with blood-elf traits.
        Request request = MakeRequest(Seed(11), "tauren", "shaman");
        request.raceVariant = "dark_iron";
        Profile const profile = BuildProfile(request);

        CHECK(!profile.variantApplied);
        CHECK(CountOrigins(profile, SourceType::RaceVariant) == 0);
        CHECK(CountOrigins(profile, SourceType::Race) == 3);
        CHECK(!HasTrait(profile, "forge_bound"));
    }

    void TestDuplicateStrengthIsTheMaximumNeverASum()
    {
        // Section 9.1's worked example is a tauren druid whose `nature_bound`
        // comes from both race and class and is stored once at 65. Which seeds
        // produce it is a property of the hash, so the sweep looks for any
        // multi-origin trait and asserts the rule on every one it finds --
        // then asserts it found some, so the test cannot pass vacuously.
        std::size_t duplicates = 0;

        for (int seedIndex = 0; seedIndex < 60; ++seedIndex)
        {
            for (std::string const& race : AllRaces())
            {
                for (std::string const& cls : AllClasses())
                {
                    Request request = MakeRequest(Seed(seedIndex), race, cls);
                    request.professionSkillIds = { 164, 186, 182, 356 };
                    Profile const profile = BuildProfile(request);

                    for (Trait const& trait : profile.traits)
                    {
                        if (trait.origins.size() < 2)
                            continue;

                        ++duplicates;

                        int highest = 0;
                        int total = 0;
                        for (Origin const& origin : trait.origins)
                        {
                            int strength = 0;
                            switch (origin.type)
                            {
                                case SourceType::Manual:      strength = catalog::kManualStrength; break;
                                case SourceType::RaceVariant: strength = catalog::kVariantStrength; break;
                                case SourceType::Class:       strength = catalog::kClassStrength; break;
                                case SourceType::Race:        strength = catalog::kRaceStrength; break;
                                case SourceType::Profession:  strength = catalog::kProfessionStrength; break;
                            }
                            highest = strength > highest ? strength : highest;
                            total += strength;
                        }

                        CHECK(trait.strength == highest);
                        CHECK(trait.strength < total);              // never a sum
                        CHECK(trait.strength <= catalog::kStrengthMax);
                    }
                }
            }
        }

        CHECK(duplicates > 0);
    }

    void TestNoProfessionsStillGetsRaceAndClass()
    {
        Request const request = MakeRequest(Seed(5), "gnome", "mage");
        Profile const profile = BuildProfile(request);

        CHECK(profile.raceKnown);
        CHECK(profile.classKnown);
        CHECK(CountOrigins(profile, SourceType::Race) == 3);
        CHECK(CountOrigins(profile, SourceType::Class) == 2);
        CHECK(CountOrigins(profile, SourceType::Profession) == 0);
        CHECK(profile.traits.size() >= 3);   // 5 unless race and class overlap
        CHECK(profile.traits.size() <= 5);
    }

    void TestUnknownIdentityIsDroppedNotInvented()
    {
        Request request = MakeRequest(Seed(9), "pandaren", "tinkerer");
        request.professionSkillIds = { 99999 };
        Profile const profile = BuildProfile(request);

        CHECK(!profile.raceKnown);
        CHECK(!profile.classKnown);
        CHECK(profile.traits.empty());
    }

    void TestDeactivatedProfessionsAreNotProvisioned()
    {
        // Section 7 keeps gardening and jewelcrafting off until someone
        // confirms this server carries them (section 14 item 4).
        Request request = MakeRequest(Seed(13), "human", "rogue");
        request.professionKeys = { "gardening", "jewelcrafting" };
        Profile const profile = BuildProfile(request);

        CHECK(CountOrigins(profile, SourceType::Profession) == 0);
        CHECK(!HasTrait(profile, "gem_minded"));
        CHECK(!HasTrait(profile, "seasonal_minded"));

        // A profession the contract lists but whose skill id is still unknown
        // is reachable by key, which is why the key list exists at all.
        Request survival = MakeRequest(Seed(13), "human", "rogue");
        survival.professionKeys = { "survival" };
        CHECK(CountOriginsFrom(BuildProfile(survival), SourceType::Profession, "survival") == 1);
    }

    void TestManualTraitOutranksEverythingAndCannotBeReplaced()
    {
        Request request = MakeRequest(Seed(2), "gnome", "warlock");
        request.manual = { ManualTrait{ "reserved", catalog::kManualStrength, true } };
        Profile const profile = BuildProfile(request);

        CHECK(HasTrait(profile, "reserved"));
        CHECK(!HasTrait(profile, "talkative"));   // the gnome pool's conflicting trait
        CHECK(CountOrigins(profile, SourceType::Manual) == 1);
        CHECK(RaceFamilySize(profile) == 3);      // the race still got its quota

        for (Trait const& trait : profile.traits)
            if (trait.key == "reserved")
                CHECK(trait.strength == catalog::kManualStrength);
    }

    void TestManualStrengthIsClamped()
    {
        Request request = MakeRequest(Seed(4), "orc", "shaman");
        request.manual = { ManualTrait{ "vigilant", 500, false } };
        Profile const profile = BuildProfile(request);

        for (Trait const& trait : profile.traits)
            if (trait.key == "vigilant")
                CHECK(trait.strength == catalog::kStrengthMax);
    }

    int DumpProfile()
    {
        Request request = MakeRequest(Seed(7), "dwarf", "warrior");
        request.professionSkillIds = { 186, 164 };
        Profile const profile = BuildProfile(request);

        std::printf("{\n  \"profile_version\": %u,\n  \"profile_seed\": \"%s\",\n  \"traits\": [\n",
                    request.profileVersion, request.profileSeed.c_str());
        for (std::size_t i = 0; i < profile.traits.size(); ++i)
        {
            Trait const& trait = profile.traits[i];
            std::printf("    {\"key\": \"%s\", \"strength\": %d, \"origins\": [",
                        trait.key.c_str(), trait.strength);
            for (std::size_t j = 0; j < trait.origins.size(); ++j)
                std::printf("%s{\"type\": \"%s\", \"key\": \"%s\"}", j ? ", " : "",
                            SourceTypeName(trait.origins[j].type), trait.origins[j].key.c_str());
            std::printf("]}%s\n", i + 1 < profile.traits.size() ? "," : "");
        }
        std::printf("  ]\n}\n");
        return 0;
    }
}   // namespace

int main(int argc, char** argv)
{
    if (argc > 1 && std::strcmp(argv[1], "--dump-profile") == 0)
        return DumpProfile();

    TestSha256MatchesThePublishedVectors();
    TestStableValueIsTheContractFormula();
    TestCatalogIsWellFormed();
    TestDeterminism();
    TestQuotasAndConflictsAcrossManySeeds();
    TestConflictResolutionActuallyFires();
    TestVariantReplacesAtMostOneRaceTrait();
    TestVariantOnTheWrongRaceIsIgnored();
    TestDuplicateStrengthIsTheMaximumNeverASum();
    TestNoProfessionsStillGetsRaceAndClass();
    TestUnknownIdentityIsDroppedNotInvented();
    TestDeactivatedProfessionsAreNotProvisioned();
    TestManualTraitOutranksEverythingAndCannotBeReplaced();
    TestManualStrengthIsClamped();

    std::printf("personality_policy_tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
