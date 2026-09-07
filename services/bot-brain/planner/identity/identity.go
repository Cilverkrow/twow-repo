// Package identity turns a bot's stable UUID into stable behavioural traits.
//
// The point is that two bots of the same class and level should not be the same
// bot. Today they are: the rule planner picks the nearest candidate POI, so any
// two bots standing in the same place with the same state make the same choice,
// forever. Identity exists in the database (ADR-0039 mints a UUID per character
// into cv_brain.bot_identity) but nothing hangs off it.
//
// Traits are DERIVED, not stored. The same UUID yields the same traits on any
// machine, in any process, with no migration, no write path and no cache to
// invalidate. That matters more than it sounds: a stored trait table would have
// to be populated for every bot before identity did anything at all, and would
// then need a repair story for rows that went missing. A pure function of the
// UUID has neither problem, and a stored table can still override it later for
// the traits that are genuinely chosen rather than computed (a home zone, a
// hand-edit) without changing anything here.
//
// Deliberately NOT an LLM. A model that assigns personalities is a personality
// that disappears when the endpoint does. These traits are arithmetic: they work
// offline, they are unit-testable, and they give the model something to be
// judged against when it arrives.
//
// Only the traits that currently change a decision live here. Fields nothing
// reads are how a stub gets mistaken for a feature -- the rest arrive with the
// actions that need them.
package identity

import (
	"crypto/sha256"
	"encoding/binary"
	"math"
)

// Traits is the derived behavioural profile of one bot.
type Traits struct {
	// Boldness is how far this bot is willing to travel, as a fraction of the
	// planner's configured ceiling. 0 is homebound, 1 is a wanderer.
	//
	// It scales the ceiling rather than replacing it: the configured
	// MaxTravelYards stays the outer bound of what the planner will ever
	// propose, because that bound exists for a server-load reason that has
	// nothing to do with personality.
	Boldness float64
}

// Neutral is the profile of a bot with no minted identity.
//
// A UUID is optional on the wire: an empty one is normal for a character the
// worldserver has not minted yet. Such a bot must behave EXACTLY as it did
// before this package existed -- nearest POI, ties broken by id -- or every
// unminted bot silently changes behaviour the day traits ship.
//
// Boldness 1 is what does that: it scales the travel ceiling by exactly 1.0 and
// produces no preference, so the selection collapses to plain nearest-first.
var Neutral = Traits{Boldness: 1}

// Derive returns the traits for a bot UUID. Empty yields [Neutral].
//
// SHA-256 rather than a fast non-cryptographic hash, and this is not paranoia:
// the input is a v4 UUID whose text differs in only a few hex digits between
// bots. A weak mixer leaves that structure visible in the output, so
// neighbouring UUIDs get neighbouring traits and a whole block of bots minted in
// one batch ends up behaving alike -- the exact failure this package exists to
// avoid. Cost is irrelevant: this is once per bot per planning batch, against a
// network call.
func Derive(uuid string) Traits {
	if uuid == "" {
		return Neutral
	}
	sum := sha256.Sum256([]byte("bot-brain/identity/v1\x00" + uuid))
	return Traits{
		// Bytes 0..7 for boldness. Mapped to [0.5, 1.5] so a bot may range half
		// again as far as the ceiling, or half of it, but never zero -- a bot
		// with a travel range of nothing is a broken bot, not a shy one.
		Boldness: 0.5 + unit(sum[0:8]),
	}
}

// RangeScale is the multiplier this bot applies to the travel ceiling.
func (t Traits) RangeScale() float64 {
	if t.Boldness <= 0 {
		return 1
	}
	return t.Boldness
}

// Affinity is this bot's stable preference for one destination, in [0, 1).
//
// Keyed on BOTH the bot and the POI, so it is a per-pair constant rather than a
// per-bot ranking: the same bot always feels the same way about the same place,
// and two bots disagree about which of two equally good places to visit. That
// disagreement is the whole point -- it is what makes a crowd of bots stop
// walking to the same POI in lockstep.
//
// An empty UUID returns 0 for every POI, which leaves ordering entirely to
// distance and then to id, exactly as before.
func Affinity(uuid, poiID string) float64 {
	if uuid == "" {
		return 0
	}
	sum := sha256.Sum256([]byte("bot-brain/identity/v1/affinity\x00" + uuid + "\x00" + poiID))
	return unit(sum[0:8])
}

// unit maps eight bytes onto [0, 1).
//
// Division rather than modulo-into-buckets: modulo would bias the low end
// whenever the bucket count does not divide 2^64, and the whole value of
// deriving traits is that the distribution is even across bots.
//
// The shift to 53 bits is what makes the interval half-open rather than closed.
// float64 has a 53-bit mantissa, so dividing the full 64-bit value by 2^64
// rounds the top of the range to exactly 1.0 -- Affinity would then be able to
// return 1, contradicting its documented range. Taking the top 53 bits and
// dividing by 2^53 is exact for every input, with a maximum of
// (2^53-1)/2^53, just under one.
func unit(b []byte) float64 {
	return float64(binary.BigEndian.Uint64(b)>>11) / math.Exp2(53)
}
