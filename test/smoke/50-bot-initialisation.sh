#!/bin/sh
# Proves: bots are actually playable, not merely present.
#
# This exists because of a defect nothing caught for the life of a realm. With
# AiPlayerbot.DisableRandomLevels set, PlayerbotFactory::Randomize returned
# before doing anything, so bots were created with no spells, no professions and
# no money, and therefore could not fight, and therefore never levelled. Measured
# when it was finally found by hand: 5,021 of 5,039 characters at level 1, 8 with
# any spell at all, 16 with any money, 2 with a profession.
#
# Every component involved was working. The roster was populated, the characters
# existed, the server was healthy, CI was green. The population was simply inert,
# and no check asked whether a bot could play -- only whether bots existed.
#
# So this asks the second question. It is deliberately about the POPULATION and
# not about one bot: a single well-formed bot proves nothing when thousands are
# empty, which is precisely the shape the defect had.
#
# The profession check asserts the PLAN, not the skill. twow-core#78 changed what
# a profession is here: InitTradeSkills records a versioned, GUID-bound pair as a
# `profession_pair` event and grants nothing -- the bot learns the skills at a
# trainer over time. Asserting the skill would therefore measure how far bots have
# walked, not whether initialisation assigned them anything.
#
# Thresholds are proportions rather than absolutes because the cohort size is a
# deployment choice. Two remain -- the profession plan and the configured
# starting level -- and both are things initialisation writes to the database
# directly, so a young world can answer them honestly. On the broken realm both
# were near zero (0.04% professioned, 0.4% above level 1); here both read 100%.
#
# The spell count is printed but no longer asserted. See the long note at the
# query for why character_spell cannot answer this question at level 1 on this
# core; it is a progression signal wearing an initialisation label, and it
# failed a healthy world six runs running.
#
# It fails rather than skips when there are no bots. "No bots" means the question
# went unanswered, and reporting that as a pass is the failure this file exists
# to prevent -- the same reasoning as 30-bot-persistence.sh.
set -eu
# shellcheck source=test/smoke/lib.sh
. "$(dirname "$0")/lib.sh"

require_stack
require_client_data

# Bots are the characters on the random-bot accounts. Joining through
# ai_playerbot_random_bots rather than guessing by name: a name convention is a
# convention, an event-store row is the server's own statement that this
# character is a bot it manages.
# Separate the two failures. A missing event store and an empty one both yield
# zero rows, and reporting "no bots" when the table is absent would send whoever
# reads it looking at the bot population instead of at the bootstrap.
store=$(dbq information_schema "
  SELECT COUNT(*) FROM TABLES
  WHERE TABLE_SCHEMA = 'cv_bots' AND TABLE_NAME = 'ai_playerbot_random_bots';"   2>/dev/null || echo 0)
[ "${store:-0}" -eq 1 ] || fail "cv_bots.ai_playerbot_random_bots is missing; the bootstrap, not the bots, is the problem"

# Only bots that have actually BEEN IN WORLD.
#
# Initialisation happens at login -- PlayerbotMgr gates InstaRandomize on
# !GetTotalPlayedTime(), i.e. first ever login -- so a character that has never
# been online cannot have been initialised, and says nothing about whether
# initialisation works. Counting the whole roster measured the login RATE
# instead: the manager keeps MinRandomBots online and works through the rest
# gradually, so a twelve-minute CI world had 20 roster entries and a handful of
# logins, and this reported 3/20 as a failure when it may well have been 3/3.
#
# totaltime is the server's own record of seconds played, so > 0 means "has been
# in world at least once" -- without this check needing to know anything about
# the login scheduler.
bots=$(dbq tw_char "
  SELECT COUNT(*) FROM characters c
  JOIN cv_bots.ai_playerbot_random_bots r ON r.bot = c.guid AND r.event = 'add'
  WHERE c.totaltime > 0;" 2>/dev/null || echo 0)
bots=${bots:-0}

# A sample of one or two would pass or fail on a coin toss. A floor means a world
# that logged nobody in fails loudly instead of passing on a single lucky bot.
if [ "$bots" -lt 3 ]; then
    fail "only $bots bot(s) have ever been in world; too few to measure initialisation"
fi

# Spells: REPORTED, NOT ASSERTED, and the reason is a property of the core.
#
# character_spell does not hold a character's class spells. Player::AddSpell
# takes (spell_id, active, learning, dependent, disabled) and
# Player::LearnDefaultSpells calls it as AddSpell(spell, true, true, true,
# false) -- dependent = true -- for every row of playercreateinfo_spell.
# Player::_SaveSpells then writes only `!itr->second.dependent` spells. So the
# race/class starters are DELIBERATELY never persisted; they are re-derived
# from playercreateinfo_spell on every load.
#
# A perfectly healthy level-1 bot therefore has ZERO rows here. What this
# column actually counts is bots that learned something BEYOND creation --
# trainer, quest reward, talent -- which is progression, not initialisation.
# In a twelve-minute CI world at the configured starting level, a small
# minority is the expected reading, and asserting a 50% floor on it failed the
# suite for a healthy world. That is the same error twice in this file: the
# profession check asserted a skill that had become a plan, and this asserted
# progression that had never been initialisation.
#
# It is still worth printing. On the realm where the original defect was found
# the number was 8 of 5,039, and over a long-running realm a floor here is a
# real signal -- bots that never learn anything are bots that never reach a
# trainer. That check belongs to a realm-health job with a horizon measured in
# days, not to a CI world that has been up for twelve minutes.
#
# Nothing else initialisation produces is observable here either, at this
# level: PlayerbotFactory::InitEquipment returns early below level 5
# (PlayerbotFactory.cpp:3021), so a level-1 bot has no equipment by design.
# The profession plan and the level are what remain, and both are asserted.
spelled=$(dbq tw_char "
  SELECT COUNT(*) FROM (
    SELECT c.guid FROM characters c
    JOIN cv_bots.ai_playerbot_random_bots r ON r.bot = c.guid AND r.event = 'add'
    JOIN character_spell s ON s.guid = c.guid
    WHERE c.totaltime > 0
    GROUP BY c.guid
  ) t;" 2>/dev/null || echo 0)

# Professions: primary trade skills only. The four skills every character holds
# by class and race are not professions and must not be counted as evidence.
professioned=$(dbq tw_char "
  SELECT COUNT(*) FROM (
    SELECT c.guid FROM characters c
    JOIN cv_bots.ai_playerbot_random_bots r ON r.bot = c.guid AND r.event = 'add'
    JOIN cv_bots.ai_playerbot_random_bots p
      ON p.bot = c.guid AND p.event = 'profession_pair'
    WHERE c.totaltime > 0
    GROUP BY c.guid
  ) t;" 2>/dev/null || echo 0)

# Against the CONFIGURED starting level, not against 1.
#
# The shipped conf sets AiPlayerbot.randombotStartingLevel = 1 and explains
# itself directly above the key: "Bots all begin at randombotStartingLevel and
# have to work their way up." On such a realm a twelve-minute-old bot at level 1
# is the configuration working, and asserting otherwise asserts against the
# deployment's own intent -- which this check did, and reported 0 of 20 as a
# failure for six runs.
#
# Comparing against the configured level instead keeps the assertion meaningful
# where it means something: set randombotStartingLevel to 5 and a bot still at 1
# has not been through Prepare(), which is a real defect and exactly the one that
# left 5,021 of 5,039 bots unable to play.
start_level=$(bot_starting_level)
levelled=$(dbq tw_char "
  SELECT COUNT(*) FROM characters c
  JOIN cv_bots.ai_playerbot_random_bots r ON r.bot = c.guid AND r.event = 'add'
  WHERE c.totaltime > 0 AND c.level >= $start_level;" 2>/dev/null || echo 0)

printf '  bots=%s spelled=%s professioned=%s at-start-level=%s\n' \
    "$bots" "${spelled:-0}" "${professioned:-0}" "${levelled:-0}"

pct() { [ "$2" -eq 0 ] && echo 0 || echo $(( $1 * 100 / $2 )); }

fails=0
check() {
    got=$(pct "$1" "$bots")
    if [ "$got" -lt "$2" ]; then
        printf '  FAIL %s: %s%% of bots (%s of %s), want at least %s%%\n' \
            "$3" "$got" "$1" "$bots" "$2"
        fails=$((fails + 1))
    fi
}

check "${professioned:-0}" 50 "have a profession PLAN"
check "${levelled:-0}"     90 "reached the configured starting level"

[ "$fails" -eq 0 ] || fail "$fails population check(s) failed; bots exist but cannot play"

pass "bots are initialised ($bots in roster)"
