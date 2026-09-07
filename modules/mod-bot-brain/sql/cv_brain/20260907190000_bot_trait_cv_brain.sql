-- Per-bot traits that CHANGE, for the out-of-process planner.
--
-- Traits start out derived: services/bot-brain/planner/identity hashes the UUID
-- from bot_identity into a stable value, so every bot is born different with no
-- row here at all. That is deliberate and it is why this table can be added
-- without a backfill -- a bot with no row has simply not changed yet, and the
-- derived value is its answer.
--
-- This table holds what EXPERIENCE changed. A bot that keeps failing to reach
-- distant places should become less bold, and that is a write. Once a row
-- exists it wins over the derived value: the bot has lived, so its traits are
-- its own rather than a function of its name.
--
-- Ownership, and the one line worth being careful about
-- -----------------------------------------------------
-- ADR-0021 gives cv_brain to mod-bot-brain, and bot_identity says of the Go
-- service: "reads the UUID off the wire and never sees a GUID". That boundary
-- survives here and is the reason this table is keyed on bot_uuid ALONE.
--
-- There is no realm column and no guid column, and adding one would be a
-- regression rather than a convenience: it would hand the planner -- the process
-- that talks to an inference endpoint -- the character identity the UUID exists
-- to keep away from it. Everything the planner needs is reachable from the UUID.
--
-- Unlike bot_identity, which the worldserver mints, this table is written by the
-- Go service. It is the side that observes outcomes and forms the plans, so it
-- is the side that learns.
--
-- A realm merge needs no update here, which is the whole point of ADR-0039:
-- RealmMerge shifts guids and bot_identity.guid moves with them, while bot_uuid
-- does not change, so every row below still resolves to the same bot.

CREATE TABLE IF NOT EXISTS `cv_brain`.`bot_trait` (
    -- Matches bot_identity.bot_uuid exactly, including charset and collation,
    -- because the foreign key below will not be created otherwise.
    `bot_uuid`   char(36)    CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- The trait's name, not a column per trait. Traits are expected to be added
    -- as the planner learns to use them (industry, sociability, a home zone),
    -- and a narrow key/value shape adds one without a migration each time.
    --
    -- The cost is that nothing here constrains the NAME, so a typo becomes a
    -- silently ignored trait rather than an error. The reader is what enforces
    -- the vocabulary: an unknown name is dropped and counted, never guessed at.
    `trait`      varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- Traits are unit-ish scalars, not enums or text. DOUBLE rather than a
    -- fixed-point type because these are weights read into float64 and compared,
    -- never summed into money.
    `value`      double      NOT NULL,

    -- Unix milliseconds, matching bot_identity.first_seen and the wire's
    -- observed_at_ms rather than SQL NOW(), so a row's age is directly
    -- comparable with everything else the brain records.
    `updated_at` bigint(20)  NOT NULL,

    -- Why the value moved. Free text, bounded, and for humans: when a bot turns
    -- out timid, the question is always "what happened to it", and a row that
    -- cannot answer that makes the trait system unauditable.
    `reason`     varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '',

    PRIMARY KEY (`bot_uuid`, `trait`),

    -- Traits belong to an identity, and they go when it does. Without the
    -- cascade, deleting a character would leave its traits behind to be
    -- inherited by whatever later minted the same UUID -- which cannot happen
    -- today, but the alternative is orphan rows nothing will ever clean up.
    CONSTRAINT `fk_bot_trait_identity` FOREIGN KEY (`bot_uuid`)
        REFERENCES `bot_identity` (`bot_uuid`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
