// Package memory is what a bot has learned from what happened to it.
//
// The worldserver already tells the brain how every intent ended -- result,
// reason, and the POI it named -- and the rule planner already uses the most
// recent one to dodge a destination for a single tick. Then it forgets. Its own
// comment names the hole: "a bot whose history the server lost across a
// restart". A place a bot cannot reach is chosen again as soon as that one-tick
// memory rolls over.
//
// Nothing here measures anything new and nothing new crosses the wire. These are
// the outcomes that already arrive, kept.
//
// Deliberately not embeddings. The question in front of us is "has this bot
// failed to get here before", which is a count. When a question arrives that a
// count cannot answer, that is the time to add a vector column -- and the design
// will be better for having a real query to answer.
package memory

import (
	"context"
	"time"
)

// Observation is one thing that happened to one bot.
type Observation struct {
	// Kind is the intent vocabulary as sent: travel_to, vendor_sell, rest.
	Kind string
	// POIID is the destination the intent named, empty when it named none.
	// This is the field the package exists for: knowing THAT something failed
	// without knowing WHERE is not enough to choose differently.
	POIID string
	// Result is "accepted", "completed", "rejected", "failed", "expired" or
	// "superseded".
	Result string
	// Reason is the machine code when the result is a refusal, empty otherwise.
	Reason string
	// ObservedAtMS is unix milliseconds, in the server's clock.
	ObservedAtMS int64
}

// Discouraging reports whether this observation is evidence against its POI.
//
// The distinction this draws is the whole reason the outcome contract carries a
// reason code at all, and getting it wrong quietly poisons every later decision:
//
//   - "failed"/"unreachable", "rejected"/"unknown_poi" and "rejected"/"stale_poi"
//     are about the DESTINATION. The bot could not get there, or the place was
//     not real. That is worth remembering against the POI.
//   - "superseded" is not. Something re-targeted the bot -- the stock chooser, a
//     group leader, an admin command, or simply nobody watching the travel to its
//     end. Counting that against the POI would teach a bot to avoid a perfectly
//     good place because a human moved it once.
//   - "expired" is about latency, not geography: the plan arrived too late to be
//     worth applying. It says "be faster", not "choose elsewhere".
//   - "rejected"/"unsupported_kind" and "action_refused" are about the KIND, not
//     the place.
func (o Observation) Discouraging() bool {
	switch o.Result {
	case "failed":
		return o.Reason == "unreachable" || o.Reason == ""
	case "rejected":
		return o.Reason == "unknown_poi" || o.Reason == "stale_poi" || o.Reason == "unreachable"
	default:
		return false
	}
}

// Reader returns what bots recently experienced.
//
// Batched by design: a planning batch may carry 2048 bots, and a lookup per bot
// inside one tick would spend the deadline before the plan did.
type Reader interface {
	// Recent returns up to perBot observations for each uuid, newest first.
	// Bots with no history are simply absent from the result -- that is the
	// normal case for a new bot and never an error.
	Recent(ctx context.Context, uuids []string, perBot int) (map[string][]Observation, error)
}

// Recorder persists observations.
//
// Separate from [Reader] because the two have opposite latency requirements:
// reading happens inside a planning deadline and must be fast or skipped;
// writing must never be inside one at all. See [AsyncRecorder].
type Recorder interface {
	Record(ctx context.Context, uuid string, o Observation) error
}

// History is one bot's recent past, indexed for the question the planner asks.
type History struct {
	discouragedPOI map[string]int
}

// Build indexes observations for lookup. A nil or empty slice yields a usable
// zero History, so callers never branch on "this bot has no history".
func Build(observations []Observation) History {
	h := History{}
	for _, o := range observations {
		if o.POIID == "" || !o.Discouraging() {
			continue
		}
		if h.discouragedPOI == nil {
			h.discouragedPOI = make(map[string]int, 4)
		}
		h.discouragedPOI[o.POIID]++
	}
	return h
}

// DiscouragedCount is how many times this bot recently failed to reach a POI in
// a way that was the destination's fault.
func (h History) DiscouragedCount(poiID string) int {
	if h.discouragedPOI == nil {
		return 0
	}
	return h.discouragedPOI[poiID]
}

// DefaultRetention bounds how much history one bot keeps.
//
// Decided now rather than when the table is large: retention added after the
// fact is a migration against a table nobody wants to lock. A bot plans every
// 15 seconds by default, so 64 rows is roughly the last quarter hour of its
// life -- long enough to notice a place it repeatedly cannot reach, short
// enough that the table stays a working set rather than an archive.
const DefaultRetention = 64

// DefaultRecentLimit is how many observations the planner reads per bot.
//
// Smaller than retention on purpose: the planner only needs enough to see a
// pattern, and the query is inside a planning deadline.
const DefaultRecentLimit = 16

// DiscouragedThreshold is how many discouraging observations it takes before the
// planner stops offering a POI to a bot.
//
// Two, not one. One failure is normal -- a mob in the way, a path that needed a
// detour, a server hiccup -- and the existing single-tick avoidance already
// covers that case without any history at all. This is for the place that fails
// EVERY time, which is what the one-tick memory could never see.
const DiscouragedThreshold = 2

// RecordTimeout bounds one write. Generous, because it happens off the planning
// path entirely and a slow write should be waited for rather than dropped.
const RecordTimeout = 5 * time.Second
