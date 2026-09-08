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
# deployment choice. They are set where a healthy realm passes comfortably and
# the measured broken realm fails on every one of them -- 0.4% spelled, 0.3%
# moneyed, 0.04% professioned against floors of 50/25/10 percent.
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

# Spells: the one that matters most. A bot with no class spells cannot kill
# anything, which is what turned a level cap setting into a permanently level-1
# population. Counted per character rather than in total, so one bot with a
# thousand spells cannot mask a thousand bots with none.
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

levelled=$(dbq tw_char "
  SELECT COUNT(*) FROM characters c
  JOIN cv_bots.ai_playerbot_random_bots r ON r.bot = c.guid AND r.event = 'add'
  WHERE c.totaltime > 0 AND c.level > 1;" 2>/dev/null || echo 0)

printf '  bots=%s spelled=%s professioned=%s above-level-1=%s\n' \
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

check "${spelled:-0}"      50 "have any spell"
check "${professioned:-0}" 50 "have a profession PLAN"
check "${levelled:-0}"     25 "are above level 1"

[ "$fails" -eq 0 ] || fail "$fails population check(s) failed; bots exist but cannot play"

pass "bots are initialised ($bots in roster)"
