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

// RefusedTheKind reports whether this observation is evidence against its
// KIND -- the mirror of [Observation.Discouraging], which is about the place.
//
// The two are deliberately separate and deliberately not the same set.
// "failed"/"action_refused" means the bot got there and the server tried: the
// destination was fine and the thing asked for was not available. Counting it
// against the POI would teach a bot to avoid a trainer because the trainer had
// nothing left to teach it, which is nonsense -- the trainer is exactly where
// it always was.
//
// But it is still evidence, and throwing it away has a cost of its own: a rung
// whose only precondition is "a POI of this kind is nearby" proposes the same
// errand every tick for as long as that POI is nearby, and a refusal that is
// remembered nowhere cannot stop it. That loop is what this exists to bound.
//
// "rejected"/"unsupported_kind" joins it because it is the strongest possible
// form of the same statement: this worldserver build cannot carry the kind out
// at all, so nothing about a different destination will help.
func (o Observation) RefusedTheKind() bool {
	switch o.Result {
	case "failed":
		return o.Reason == "action_refused"
	case "rejected":
		return o.Reason == "unsupported_kind" || o.Reason == "action_refused"
	default:
		return false
	}
}

// History is one bot's recent past, indexed for the questions the planner asks.
type History struct {
	discouragedPOI map[string]int
	refusedKind    map[string]int
}

// Build indexes observations for lookup. A nil or empty slice yields a usable
// zero History, so callers never branch on "this bot has no history".
func Build(observations []Observation) History {
	h := History{}
	for _, o := range observations {
		if o.Kind != "" && o.RefusedTheKind() {
			if h.refusedKind == nil {
				h.refusedKind = make(map[string]int, 2)
			}
			h.refusedKind[o.Kind]++
		}
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

// KindRefusedCount is how many times this bot was recently refused an intent of
// this kind for a reason that was about the kind rather than the destination.
//
// Note that it does NOT decay to zero on a success, and that is on purpose: the
// planner only ever reads it against a threshold, and what bounds it is the
// window. Recent() reads the last [DefaultRecentLimit] observations, so a
// refusal ages out of the answer after that many plans no matter what happened
// in between -- which turns "stop asking" into "ask again in a while" without
// anything having to decide when the while is over.
func (h History) KindRefusedCount(kind string) int {
	if h.refusedKind == nil {
		return 0
	}
	return h.refusedKind[kind]
}

// KindRefusedThreshold is how many refusals of a KIND it takes before the
// planner stops proposing it for a while.
//
// Two, for the same reason [DiscouragedThreshold] is two: one refusal is
// normal. A trainer with nothing to teach today has something to teach after
// the next level, and a bot that stopped asking on the first no would train
// once and never again.
const KindRefusedThreshold = 2

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
