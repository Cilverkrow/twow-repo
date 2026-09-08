-- The personality profile a bot was born with (personality context contract v1).
--
-- Section 4.2 is the whole reason this table exists: "ein Profil wird einmal
-- erzeugt und dann gespeichert", and changing a pool must not silently rewrite
-- the bots that were already generated from it. PersonalityPolicy.h is a pure
-- function of (profile_version, seed, race, variant, class, professions), so a
-- profile could in principle be recomputed on every login and never stored at
-- all -- and that is exactly the design section 4.2 forbids. Edit a pool and
-- every existing bot's personality would quietly change underneath the players
-- who had already met it. The row below is what makes the profile a fact rather
-- than a derivation.
--
-- Two deliberate divergences from the written contract
-- ---------------------------------------------------
-- 1. KEYED ON bot_uuid, NOT bot_guid. Section 13 keys `ai_bot_personality` on
--    the bot GUID. This table does not, and the divergence is intentional
--    (ADR-0039, ADR-0040): core/tools/RealmMerge/RealmMerge.cpp:190 does
--
--        UPDATE `characters` SET `guid` = (`guid` + %u)
--
--    so a realm merge shifts every GUID and anything keyed on one afterwards
--    names a different character. A personality is the single worst thing in
--    this schema to attach to the wrong bot: it is permanent by construction,
--    so the mistake would never self-correct. bot_identity already owns the
--    stable key, and the FK below means a bot's personality travels with it.
--
--    It is also why there is no realm column and no guid column here, the same
--    boundary bot_trait states: the process that reads this row talks to an
--    inference endpoint and has no business knowing a character identity.
--
-- 2. ONE ROW PER BOT, NOT ONE ROW PER TRAIT. Section 13 splits the profile
--    across `ai_bot_traits` and `ai_bot_trait_origins`. This stores the chosen
--    keys as one ordered ascii list, because the two properties that matter
--    here are both properties of the PROFILE and not of a trait:
--
--      - Atomicity. "Generated once" has to be observable as one thing. With a
--        row per trait, a second worldserver thread reading while a first is
--        still inserting sees a real but incomplete profile and has no way to
--        tell it apart from a finished one. A single row either exists whole or
--        does not exist, with no transaction to get wrong.
--      - What is actually consumed. The wire carries char.trait_keys (a list of
--        keys, BotBrainWire.cpp) and nothing else; strengths and origins have no
--        reader yet.
--
--    The cost, stated plainly: nothing can index or query by individual trait,
--    and giving strengths and origins a home when the prompt builder needs them
--    will take a migration rather than a column that was already there. Both are
--    recoverable; a half-written profile that reads as complete is not.
--
-- Owner: mod-bot-brain owns cv_brain (ADR-0021). The worldserver writes this
-- table once per bot, from the same off-thread worker that mints the identity;
-- the Go service never writes it.

CREATE TABLE IF NOT EXISTS `cv_brain`.`bot_personality` (
    -- Matches bot_identity.bot_uuid exactly, including charset and collation,
    -- because the foreign key below will not be created otherwise. This value
    -- is also the profile_seed section 4.1 hashes, so the key and the input are
    -- the same string -- there is no second identifier to keep in step.
    `bot_uuid`         char(36)     CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- ai::personality::kProfileVersion at the moment the row was written.
    -- Section 4.2 makes a version bump the ONE sanctioned way to re-roll every
    -- bot, so this column is what tells a re-roll ("the stored version is older
    -- than mine, regenerate") apart from an ordinary pool edit ("same version,
    -- keep what is stored"). Without it the two are indistinguishable and the
    -- contract's promise cannot be kept in either direction.
    `profile_version`  int(10) unsigned NOT NULL,

    -- The resolved trait keys, comma-separated, in the order the policy emits
    -- them (sorted by key, so the column is directly comparable between bots and
    -- between runs). ascii because every key in PersonalityCatalog.h is ascii by
    -- construction -- the German labels live in the traits.json catalog and the
    -- prompt builder, never here.
    --
    -- 1024 is roughly four times the worst case a full profile can reach today
    -- (3 race + 1 variant + 2 class + one per learned profession, keys under 30
    -- characters), so the truncation this column could suffer is not reachable
    -- by adding a pool -- only by redefining what a profile is, which is a
    -- version bump and a migration anyway.
    `trait_keys`       varchar(1024) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- Unix milliseconds, matching bot_identity.first_seen and the wire's
    -- observed_at_ms rather than SQL NOW(), so a row's age is directly
    -- comparable with everything else the brain records.
    `generated_at`     bigint(20)   NOT NULL,

    PRIMARY KEY (`bot_uuid`),

    -- A personality belongs to an identity and goes when it does, same cascade
    -- and same reason as bot_trait: an orphan profile would be inherited by
    -- whatever later held the same UUID, which cannot happen today and would be
    -- unfixable if it ever did.
    CONSTRAINT `fk_bot_personality_identity` FOREIGN KEY (`bot_uuid`)
        REFERENCES `bot_identity` (`bot_uuid`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
