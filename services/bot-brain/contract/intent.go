package contract

import "fmt"

// IntentKind is the closed set of things the brain may suggest.
//
// The set is closed on purpose. Every kind here is something the worldserver
// already knows how to do and can validate before doing. There is deliberately
// no kind that creates, deletes, relocates, re-rolls, logs out or substitutes a
// bot: ADR-0024 invariant 1 is enforced by the absence of vocabulary, not by a
// runtime check that somebody could forget to write. Adding a kind is a MINOR
// contract change; adding a kind that touches identity is not a contract change
// at all, it is a rejected change.
//
// Unknown kinds arriving at either end must be ignored, not rejected. A newer
// brain talking to an older worldserver will emit kinds the server does not
// implement; the server drops those intents and the bot keeps running tier-0
// AI, which is always correct, merely less interesting.
type IntentKind string

const (
	// IntentIdle: do nothing new; keep running in-core AI. This is the correct
	// answer far more often than it looks, and it is the answer every planner
	// must be able to give. It is never wrong, only unambitious.
	IntentIdle IntentKind = "idle"

	// IntentTravelTo: move to the POI named in [TravelParams.POIID]. The server
	// paths it. The brain never supplies waypoints or coordinates.
	IntentTravelTo IntentKind = "travel_to"

	// IntentPickQuest: accept the quest offered at a "quest_giver" POI.
	IntentPickQuest IntentKind = "pick_quest"

	// IntentTurnInQuest: hand in a completed quest at a "quest_turnin" POI.
	IntentTurnInQuest IntentKind = "turn_in_quest"

	// IntentAbandonQuest: drop a quest from the log. This touches progression,
	// not identity: the character, its GUID, its items and its history are
	// untouched. It exists because a bot stuck on an impossible quest otherwise
	// travels to the same unreachable hotspot forever.
	IntentAbandonQuest IntentKind = "abandon_quest"

	// IntentGrindArea: kill things around the POI named in the params until the
	// server decides otherwise. The coarse "just level up" answer.
	IntentGrindArea IntentKind = "grind_area"

	// IntentVendorSell: travel to a vendor POI and sell greys. The answer to
	// full bags.
	IntentVendorSell IntentKind = "vendor_sell"

	// IntentRepair: travel to a repair POI and repair. The answer to low
	// durability.
	IntentRepair IntentKind = "repair"

	// IntentRest: eat, drink or sit until recovered. Cheap and always
	// available; the fallback answer for a hurt bot with nowhere useful to go.
	IntentRest IntentKind = "rest"
)

// KnownIntentKinds is every kind this build emits or understands. It is served
// from the /v1/contract endpoint so the C++ side can detect skew at startup
// rather than discovering it one dropped intent at a time.
var KnownIntentKinds = []IntentKind{
	IntentIdle,
	IntentTravelTo,
	IntentPickQuest,
	IntentTurnInQuest,
	IntentAbandonQuest,
	IntentGrindArea,
	IntentVendorSell,
	IntentRepair,
	IntentRest,
}

// IsKnown reports whether this build understands the kind. Callers use it to
// *ignore* unknown kinds, never to reject a whole batch.
func (k IntentKind) IsKnown() bool {
	for _, known := range KnownIntentKinds {
		if k == known {
			return true
		}
	}
	return false
}

// TravelParams carries the destination for the POI-directed kinds
// ([IntentTravelTo], [IntentGrindArea], [IntentVendorSell], [IntentRepair],
// [IntentPickQuest], [IntentTurnInQuest]).
type TravelParams struct {
	// POIID must be the [PointOfInterest.ID] of a POI that was in the same
	// snapshot. Any other value is a stale or invented destination and the
	// server drops it with reason "unknown_poi".
	POIID string `json:"poi_id"`
	// StopWithinYards is how close is close enough. Absent means the server
	// picks a sensible default for the POI kind (interaction range for a
	// vendor, a wide radius for a grind area). A planner should usually leave
	// it absent; the server knows the ranges and the brain does not.
	StopWithinYards *float64 `json:"stop_within_yards,omitempty"`
}

// QuestParams carries the quest for [IntentAbandonQuest], and optionally
// disambiguates which quest a turn-in or pick-up refers to when the POI offers
// more than one.
type QuestParams struct {
	// QuestID must appear in the snapshot's quest log for an abandon, or be
	// related to the named POI for a pick-up or turn-in.
	QuestID uint32 `json:"quest_id"`
}

// Intent is one suggestion for one bot.
//
// It is advisory. The worldserver revalidates it against live state and may
// reject it; rejection is reported back on the next snapshot's
// [Snapshot.LastOutcome] and is a normal, expected outcome. Nothing here
// executes anything: the brain names a goal, the server decides whether and how
// to pursue it.
type Intent struct {
	// Bot is the bot this intent is for. It MUST equal the [Snapshot.Bot] it
	// was planned from. The server drops any intent whose Bot it did not ask
	// about in this batch; that check is what makes a planner bug produce a
	// dropped intent rather than a bot acting on another bot's plan.
	Bot BotID `json:"bot"`

	// IntentID is a unique id for this intent, generated by the brain. It is
	// opaque to the server, which echoes it back in [IntentOutcome.IntentID].
	// It exists so outcomes can be attributed without either side keeping a
	// correlation table.
	IntentID string `json:"intent_id"`

	// Kind is what to do. Required.
	Kind IntentKind `json:"kind"`

	// Travel is set for the POI-directed kinds and nil otherwise.
	Travel *TravelParams `json:"travel,omitempty"`
	// Quest is set for [IntentAbandonQuest], and may be set on a pick-up or
	// turn-in to disambiguate. Nil otherwise.
	Quest *QuestParams `json:"quest,omitempty"`

	// Priority orders competing intents for the same bot within one response,
	// higher first. In practice the brain emits one intent per bot per batch,
	// so this matters only when a future planner starts proposing alternatives.
	// Zero is the normal value.
	Priority int32 `json:"priority,omitempty"`

	// Confidence in [0, 1]. Advisory: the server may configure a floor below
	// which it ignores intents entirely, which is how a badly-behaving LLM
	// planner gets defanged without a redeploy. Zero means "not stated", which
	// a server with a floor configured will treat as below the floor.
	Confidence float64 `json:"confidence,omitempty"`

	// ExpiresAtMS is when this intent stops being valid, in the *server's*
	// clock. The brain computes it as the request's [PlanRequest.SentAtMS] plus
	// a TTL, deliberately never from its own clock, because the two processes
	// have no shared time base. The server discards expired intents on arrival.
	//
	// This is the main defence against a slow brain: an intent that took eight
	// seconds to produce arrives already expired and is silently dropped rather
	// than sending a bot somewhere it decided to go a long time ago.
	//
	// Zero means "no expiry", which the server is entitled to treat as a very
	// short default rather than as forever.
	ExpiresAtMS int64 `json:"expires_at_ms,omitempty"`

	// Source records which planner produced this: "rule", "llm", or "fallback"
	// when a fallback planner answered because the primary timed out or failed.
	// It is for metrics and debugging and has no behavioural meaning.
	Source string `json:"source,omitempty"`

	// Rationale is a short human-readable explanation, capped at
	// [MaxRationaleBytes]. It exists for operators reading logs.
	//
	// It MUST NOT be shown to players. It is not sanitised for chat delivery,
	// it may contain GUIDs and internal identifiers, and for the LLM planner it
	// is model-generated text that has not been through the validator layer
	// (ARCH-002). Bot *speech* is a different subsystem and does not travel on
	// this contract.
	Rationale string `json:"rationale,omitempty"`
}

// MaxRationaleBytes caps the debug string so a chatty model cannot inflate a
// 1000-bot response.
const MaxRationaleBytes = 256

// Validate checks an intent is internally consistent and carries the params its
// kind requires. Planners run this on their own output before returning it, so
// that a planner bug becomes a dropped intent and a metric here rather than a
// rejected intent and a confused bot two processes away.
func (i *Intent) Validate() error {
	if i.Bot.GUID == 0 || i.Bot.Realm == 0 {
		return fmt.Errorf("%w: intent %q has no bot identity", ErrMalformed, i.IntentID)
	}
	if i.IntentID == "" {
		return fmt.Errorf("%w: intent for bot %s has no intent_id", ErrMalformed, i.Bot)
	}
	if !i.Kind.IsKnown() {
		return fmt.Errorf("%w: intent %q has unknown kind %q", ErrMalformed, i.IntentID, i.Kind)
	}
	if i.Confidence < 0 || i.Confidence > 1 {
		return fmt.Errorf("%w: intent %q has confidence %v outside 0..1", ErrMalformed, i.IntentID, i.Confidence)
	}
	switch i.Kind {
	case IntentTravelTo, IntentGrindArea, IntentVendorSell, IntentRepair,
		IntentPickQuest, IntentTurnInQuest:
		if i.Travel == nil || i.Travel.POIID == "" {
			return fmt.Errorf("%w: intent %q of kind %q needs travel.poi_id", ErrMalformed, i.IntentID, i.Kind)
		}
	case IntentAbandonQuest:
		if i.Quest == nil || i.Quest.QuestID == 0 {
			return fmt.Errorf("%w: intent %q of kind %q needs quest.quest_id", ErrMalformed, i.IntentID, i.Kind)
		}
	case IntentIdle, IntentRest:
		// No params. Always valid, which is what makes them safe fallbacks.
	}
	if len(i.Rationale) > MaxRationaleBytes {
		return fmt.Errorf("%w: intent %q rationale is %d bytes, cap is %d",
			ErrMalformed, i.IntentID, len(i.Rationale), MaxRationaleBytes)
	}
	return nil
}

// Idle builds the always-safe intent for a bot. Every planner needs this, and
// having exactly one construction of it means "do nothing" is never accidentally
// expressed as an empty or malformed intent.
func Idle(bot BotID, intentID, source, rationale string) Intent {
	if len(rationale) > MaxRationaleBytes {
		rationale = rationale[:MaxRationaleBytes]
	}
	return Intent{
		Bot:        bot,
		IntentID:   intentID,
		Kind:       IntentIdle,
		Confidence: 1,
		Source:     source,
		Rationale:  rationale,
	}
}
