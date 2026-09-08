package contract

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func strategyIntent(changes ...StrategyChange) Intent {
	return Intent{
		Bot:        BotID{Realm: 1, GUID: 42},
		IntentID:   "i1",
		Kind:       IntentSetStrategies,
		Strategies: &StrategyParams{Changes: changes},
	}
}

// ValidStrategyName is a SAFETY check before it is a tidiness one, and this is
// where that claim is kept honest. PlayerbotAI::ChangeStrategy takes one string,
// splits it on ',' and reads the first byte of each part as the operator, so a
// name that carries a comma smuggles in a second directive nobody reviewed and a
// name that starts with an operator inverts the one the server meant to write.
func TestValidStrategyName(t *testing.T) {
	valid := []string{"grind", "rpg", "conserve mana", "rpg vendor", "debug travel", "bot brain"}
	for _, name := range valid {
		if !ValidStrategyName(name) {
			t.Errorf("ValidStrategyName(%q) = false, want true; that is a name this build's C++ side registers", name)
		}
	}

	invalid := map[string]string{
		"":                      "a nameless change names no work",
		" grind":                "leading space",
		"grind ":                "trailing space",
		"conserve  mana":        "doubled space is never a registered name",
		"grind,-flee":           "a comma is a second, unreviewed directive",
		"+grind":                "a leading operator inverts the entry the server writes",
		"-grind":                "a leading operator inverts the entry the server writes",
		"~grind":                "a leading operator inverts the entry the server writes",
		"grind\nflee":           "a newline forges a second log line",
		"grind\x00flee":         "a NUL truncates the name at the C++ boundary",
		strings.Repeat("a", 65): "over MaxStrategyNameBytes",
		"rpg/vendor":            "punctuation is not part of any registered name",
	}
	for name, why := range invalid {
		if ValidStrategyName(name) {
			t.Errorf("ValidStrategyName(%q) = true, want false: %s", name, why)
		}
	}

	// Exactly at the cap is fine; one over is not. Checked because an
	// off-by-one here would either reject legitimate names forever or let the
	// cap stop capping.
	if !ValidStrategyName(strings.Repeat("a", MaxStrategyNameBytes)) {
		t.Errorf("a name of exactly MaxStrategyNameBytes (%d) must be valid", MaxStrategyNameBytes)
	}
}

func TestBotStateNames(t *testing.T) {
	for _, state := range KnownBotStates {
		if !state.IsKnown() {
			t.Errorf("%q is in KnownBotStates but IsKnown() rejects it", state)
		}
	}
	// No "all". BOT_STATE_ALL exists in the C++ enum and fans a change out to
	// every engine; offering it here would let one entry make four edits the
	// planner never reasoned about.
	for _, state := range []BotStateName{"", "all", "noncombat", "COMBAT", "0"} {
		if state.IsKnown() {
			t.Errorf("BotStateName(%q).IsKnown() = true, want false", state)
		}
	}
}

func TestSetStrategiesValidate(t *testing.T) {
	ok := strategyIntent(
		StrategyChange{Name: "grind", State: BotStateNonCombat},
		StrategyChange{Name: "conserve mana", State: BotStateCombat, Enable: true},
	)
	if err := ok.Validate(); err != nil {
		t.Fatalf("a well-formed set_strategies must validate, got: %v", err)
	}

	// The same (name, state) twice has no single meaning, and the two orders
	// give opposite results. Refused here rather than letting whichever the
	// server applies last silently win.
	dup := strategyIntent(
		StrategyChange{Name: "grind", State: BotStateNonCombat, Enable: true},
		StrategyChange{Name: "grind", State: BotStateNonCombat},
	)
	if err := dup.Validate(); !errors.Is(err, ErrMalformed) {
		t.Errorf("a duplicated (name, state) must be malformed, got: %v", err)
	}

	// The same NAME in two different states is a normal thing to want: "rpg"
	// out of combat and not in it is one coherent decision.
	twoStates := strategyIntent(
		StrategyChange{Name: "flee", State: BotStateNonCombat},
		StrategyChange{Name: "flee", State: BotStateCombat, Enable: true},
	)
	if err := twoStates.Validate(); err != nil {
		t.Errorf("the same name in two states must validate, got: %v", err)
	}

	bad := map[string]Intent{
		"no params at all": {
			Bot: BotID{Realm: 1, GUID: 42}, IntentID: "i1", Kind: IntentSetStrategies,
		},
		"an empty set": strategyIntent(),
		"an unknown state": strategyIntent(
			StrategyChange{Name: "grind", State: BotStateName("all")}),
		"an impossible name": strategyIntent(
			StrategyChange{Name: "grind,-flee", State: BotStateNonCombat}),
	}
	for why, in := range bad {
		if err := in.Validate(); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s must be malformed, got: %v", why, err)
		}
	}

	// An empty set is refused rather than read as "clear everything". This
	// module never takes ownership of a bot's whole strategy set, so there is
	// no such instruction to express, and treating the empty case as one would
	// make a planner bug into an inert bot.
	empty := strategyIntent()
	if err := empty.Validate(); err == nil {
		t.Error("an empty change list must not validate; there is no 'clear everything' instruction")
	}

	// Over the cap. The bound exists so one bot's intent cannot become
	// unbounded work on a map thread.
	over := make([]StrategyChange, MaxStrategyChanges+1)
	for i := range over {
		over[i] = StrategyChange{Name: "s" + string(rune('a'+i%26)) + string(rune('a'+i/26)), State: BotStateCombat}
	}
	overIntent := strategyIntent(over...)
	if err := overIntent.Validate(); !errors.Is(err, ErrMalformed) {
		t.Errorf("more than MaxStrategyChanges (%d) must be malformed", MaxStrategyChanges)
	}
}

// The field must actually be OMITTED for every other kind. A `"strategies":
// null` on an idle intent would be a key the C++ decoder reads and finds empty,
// which is indistinguishable on the wire from "an empty set was requested" --
// the one thing Validate refuses to let anybody express.
func TestStrategiesOmittedForOtherKinds(t *testing.T) {
	body, err := json.Marshal(Idle(BotID{Realm: 1, GUID: 42}, "i1", "rule", "nothing to do"))
	if err != nil {
		t.Fatalf("marshalling an idle intent: %v", err)
	}
	if strings.Contains(string(body), "strategies") {
		t.Errorf("idle intent carries a strategies key: %s", body)
	}
}

// set_strategies must be advertised, or a peer treats a legitimate intent as
// unknown and drops it silently.
func TestSetStrategiesIsAdvertised(t *testing.T) {
	if !IntentSetStrategies.IsKnown() {
		t.Fatal("set_strategies is not in KnownIntentKinds; every peer would drop it")
	}
}
