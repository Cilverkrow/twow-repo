-- What happened to a bot, so the next decision can depend on it.
--
-- The worldserver already reports every intent's outcome -- result, reason, and
-- the POI it named -- and the planner already uses the most recent one to dodge
-- a destination for a single tick. Then it forgets. The rule planner's own
-- comment admits the gap: "a bot whose history the server lost across a
-- restart". A POI a bot can never reach is re-chosen the moment that one-tick
-- memory rolls over.
--
-- This is that history kept. Nothing new is measured and nothing new crosses the
-- wire: these rows are Snapshot.last_outcome, written down instead of discarded.
--
-- Deliberately NOT embeddings
-- ---------------------------
-- ADR-0027 and the LLM PoC gesture at MariaDB VECTOR with HNSW and cosine
-- distance. That is a large dependency for a question nobody has asked yet. The
-- question actually in front of us is "has this bot failed to reach this place
-- before", which is a count over a small table with an index on it. When a
-- question arrives that this shape genuinely cannot answer, that is the moment
-- to add a vector column -- not before, and the answer will be better for having
-- a real query to design against.
--
-- Ownership and the identity boundary
-- -----------------------------------
-- Written and read by the Go service, keyed on bot_uuid ALONE. No realm column
-- and no guid column, for the same reason bot_trait has none: this is the
-- process that talks to an inference endpoint, and bot_identity states of it
-- that it "reads the UUID off the wire and never sees a GUID". Everything the
-- planner needs is reachable from the UUID.
--
-- A realm merge needs no update here. That is the whole point of ADR-0039:
-- RealmMerge shifts guids, bot_identity.guid moves with them, bot_uuid does not
-- change, and every row below still resolves to the same bot.

CREATE TABLE IF NOT EXISTS `cv_brain`.`bot_observation` (
    -- Surrogate key so retention can delete by age cheaply and so two identical
    -- outcomes a second apart are two rows rather than one lost.
    `id`          bigint(20) unsigned NOT NULL AUTO_INCREMENT,

    -- Matches bot_identity.bot_uuid exactly, charset and collation included,
    -- or the foreign key below will not be created.
    `bot_uuid`    char(36)     CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- The intent vocabulary, as sent: travel_to, vendor_sell, rest, and so on.
    -- Unconstrained on purpose -- the contract owns that list, and a database
    -- that disagreed with it would reject rows describing perfectly real events.
    `kind`        varchar(32)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- The destination the intent named, empty when it named none. This is the
    -- column the whole table exists for: without it a planner learns THAT
    -- something failed and not WHERE, which is not enough to choose differently.
    `poi_id`      varchar(64)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',

    -- "accepted" | "completed" | "rejected" | "failed" | "expired" | "superseded"
    `result`      varchar(16)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL,

    -- "unreachable" | "stale_poi" | "unknown_poi" | "unsupported_kind" |
    -- "action_refused" | "" -- the machine codes from the wire contract.
    `reason`      varchar(32)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',

    -- Unix milliseconds, matching bot_identity.first_seen and the wire's
    -- observed_at_ms rather than SQL NOW(), so ages stay comparable across
    -- everything the brain records.
    `observed_at` bigint(20)   NOT NULL,

    PRIMARY KEY (`id`),

    -- The query this table is read by, and the only one: "what has this bot
    -- recently experienced". Newest first, hence the descending time, so the
    -- planner reads a short prefix rather than sorting the bot's whole history
    -- on every batch.
    KEY `idx_bot_recent` (`bot_uuid`, `observed_at` DESC),

    -- Observations belong to an identity and go when it does, exactly as traits
    -- do. Without the cascade, deleting a character leaves its history to be
    -- inherited by whatever later mints the same UUID.
    CONSTRAINT `fk_bot_observation_identity` FOREIGN KEY (`bot_uuid`)
        REFERENCES `bot_identity` (`bot_uuid`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
