-- Stable bot identity for the out-of-process planner (ADR-0039).
--
-- The brain must remember things about a bot across restarts, and to do that it
-- needs a key that outlives the character's game identity. It cannot use
-- (realm, guid) and it cannot derive one from them, because
-- core/tools/RealmMerge/RealmMerge.cpp:190 does:
--
--     UPDATE `characters` SET `guid` = (`guid` + %u)
--
-- A realm merge shifts every GUID by an offset. Anything derived from a GUID
-- therefore names a different bot afterwards, and every stored fact about that
-- bot is silently orphaned with no way to repair it - the identity would be a
-- pure function of a value that moved.
--
-- So the UUID is minted once, stored, and never recomputed. When a merge shifts
-- GUIDs, the `guid` column below takes the same `+ offset` as the twenty other
-- tables that tool already updates, the UUID does not change, and every row the
-- brain wrote still resolves to the same bot.
--
-- IF THAT UPDATE IS EVER FORGOTTEN, brain state attaches to the WRONG
-- character. That is the worst outcome available here, which is why it is
-- written down in three places: here, in ADR-0039, and next to the merge.
--
-- Owner: mod-bot-brain owns cv_brain (ADR-0021). mod-bot-brain writes this
-- table; the Go service reads the UUID off the wire and never sees a GUID.

CREATE TABLE IF NOT EXISTS `cv_brain`.`bot_identity` (
    -- A version-4 UUID in canonical 8-4-4-4-12 form. ascii_bin rather than the
    -- table default: this is a fixed-width hex key that is only ever compared
    -- for exact equality, so a case-insensitive multi-byte collation would cost
    -- index size and buy nothing.
    `bot_uuid`   char(36)        CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- The game identity this UUID currently points at. BOTH columns are needed:
    -- GUIDs are only unique within a realm.
    `realm`      int(10) unsigned    NOT NULL,
    `guid`       bigint(20) unsigned NOT NULL,

    -- Unix milliseconds, matching the wire's observed_at_ms rather than SQL
    -- NOW(), so a row's age is comparable with everything else the brain logs.
    `first_seen` bigint(20)      NOT NULL,

    PRIMARY KEY (`bot_uuid`),

    -- One UUID per character, enforced rather than assumed. Without this a
    -- concurrent mint on two map threads would give one bot two identities and
    -- split its memory in half.
    UNIQUE KEY `uq_realm_guid` (`realm`, `guid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
