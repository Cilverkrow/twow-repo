package identity

import (
	"math"
	"testing"
)

func base(b float64) Traits { return Traits{Boldness: b} }

// The reason the package reads §8 instead of the English words. If someone
// "fixes" these by intuition, bots start ranging in the opposite direction from
// the personality the contract gave them, and nothing fails.
func TestTheKeysThatLookBoldAndAreNot(t *testing.T) {
	for _, tc := range []struct {
		key string
		why string
	}{
		{"fearless", "§8 defines it as calm about unpleasant CRAFT WORK, not danger"},
		{"reserved", "§8 is about how much a bot discloses, not where it goes"},
		{"patient", "§8 is about not pressing others, not about distance"},
	} {
		t.Run(tc.key, func(t *testing.T) {
			got := ApplyKeys(base(1.0), []string{tc.key})
			if got.Boldness != 1.0 {
				t.Fatalf("%q moved boldness to %v -- %s", tc.key, got.Boldness, tc.why)
			}
		})
	}

	// And the one that reads bold but means cautious.
	if got := ApplyKeys(base(1.0), []string{"wilderness_savvy"}); got.Boldness >= 1.0 {
		t.Fatalf("wilderness_savvy raised boldness to %v; §8 has it preferring "+
			"cautious progress and only known locations", got.Boldness)
	}
}

func TestTheKeysThatDoMove(t *testing.T) {
	for _, k := range []string{"risk_taking", "curious", "outdoorsy", "free_spirited"} {
		if got := ApplyKeys(base(1.0), []string{k}); got.Boldness <= 1.0 {
			t.Fatalf("%q left boldness at %v, want higher", k, got.Boldness)
		}
	}
	for _, k := range []string{"wary", "mistrustful", "wilderness_savvy"} {
		if got := ApplyKeys(base(1.0), []string{k}); got.Boldness >= 1.0 {
			t.Fatalf("%q left boldness at %v, want lower", k, got.Boldness)
		}
	}
}

// Most of the contract's 124 keys are about conversation. An unrecognised key
// must produce no opinion, the same way an unknown STORED trait is dropped
// rather than guessed at.
func TestUnknownKeysAreIgnored(t *testing.T) {
	got := ApplyKeys(base(1.0), []string{"storyteller", "dry_humor", "gem_minded", "not-a-trait", ""})
	if got.Boldness != 1.0 {
		t.Fatalf("conversational keys moved boldness to %v", got.Boldness)
	}
}

// A bot holds several keys at once, and opposite ones must actually cancel --
// otherwise ordering inside the pool decides the bot's personality.
func TestOpposingKeysCancel(t *testing.T) {
	got := ApplyKeys(base(1.0), []string{"curious", "wary"})
	if math.Abs(got.Boldness-1.0) > 1e-9 {
		t.Fatalf("curious + wary landed on %v, want 1.0", got.Boldness)
	}
}

// Personality moves a bot within the range of possible bots, never outside it --
// the same band Derive produces and stored traits are clamped to.
func TestKeysCannotEscapeTheBand(t *testing.T) {
	all := []string{"risk_taking", "curious", "outdoorsy", "free_spirited"}
	if got := ApplyKeys(base(boldnessMax), all); got.Boldness > boldnessMax {
		t.Fatalf("boldness reached %v, above the ceiling %v", got.Boldness, boldnessMax)
	}
	down := []string{"wary", "mistrustful", "wilderness_savvy"}
	if got := ApplyKeys(base(boldnessMin), down); got.Boldness < boldnessMin {
		t.Fatalf("boldness reached %v, below the floor %v", got.Boldness, boldnessMin)
	}
}

// The precedence that keeps this from fighting memory. A learned value is
// evidence about THIS bot; a trait key is a statement about it before it had
// been anywhere. Applying keys on top would also re-apply the same offset every
// tick and walk the bot to a bound within minutes.
func TestALearnedBotIsNotNudgedByItsBirthPersonality(t *testing.T) {
	learned := Traits{Boldness: 0.9, Learned: true}
	got := ApplyKeys(learned, []string{"risk_taking", "curious", "outdoorsy"})
	if got != learned {
		t.Fatalf("keys moved a learned profile from %+v to %+v", learned, got)
	}
}

// Applying twice must not move twice: it runs every tick.
func TestApplyingIsNotCumulativeAcrossTicks(t *testing.T) {
	once := ApplyKeys(base(1.0), []string{"curious"})
	twice := ApplyKeys(base(1.0), []string{"curious"})
	if once != twice {
		t.Fatalf("two independent applications disagreed: %+v vs %+v", once, twice)
	}
}

// A bot with no personality assigned must behave exactly as it did before this
// file existed, for the same reason Neutral exists.
func TestNoKeysChangesNothing(t *testing.T) {
	for _, keys := range [][]string{nil, {}} {
		if got := ApplyKeys(base(1.0), keys); got != base(1.0) {
			t.Fatalf("keys %v produced %+v", keys, got)
		}
	}
}

// The step is small on purpose: several mild traits must not erase the derived
// identity underneath by pinning a bot to a bound.
func TestOneSidedPersonalityDoesNotPinTheBot(t *testing.T) {
	got := ApplyKeys(base(1.0), []string{"risk_taking", "curious", "outdoorsy"})
	if got.Boldness >= boldnessMax {
		t.Fatalf("three bold traits reached the ceiling (%v); the derived value "+
			"no longer matters for such a bot", got.Boldness)
	}
}
