package memory

import (
	"context"
	"errors"
	"math"
	"testing"
)

type fakeHistory struct {
	obs []Observation
	err error
}

func (f *fakeHistory) Recent(_ context.Context, uuids []string, _ int) (map[string][]Observation, error) {
	if f.err != nil {
		return nil, f.err
	}
	out := make(map[string][]Observation, len(uuids))
	for _, u := range uuids {
		out[u] = f.obs
	}
	return out, nil
}

type fakeTraits struct {
	values  map[string]map[string]float64
	writes  []write
	err     error
	loadErr error
}

type write struct {
	uuid, trait, reason string
	value               float64
}

func (f *fakeTraits) Set(_ context.Context, uuid, trait string, value float64, reason string) error {
	if f.err != nil {
		return f.err
	}
	f.writes = append(f.writes, write{uuid: uuid, trait: trait, value: value, reason: reason})
	return nil
}

func (f *fakeTraits) Load(_ context.Context, _ []string) (map[string]map[string]float64, error) {
	if f.loadErr != nil {
		return nil, f.loadErr
	}
	return f.values, nil
}

func repeat(o Observation, n int) []Observation {
	out := make([]Observation, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, o)
	}
	return out
}

const learnUUID = "f47ac10b-58cc-4372-a567-0000000000aa"

func learner(hist []Observation, traits *fakeTraits) *Learner {
	return &Learner{
		Reader:  &fakeHistory{obs: hist},
		Traits:  traits,
		Values:  traits,
		Derived: func(string) float64 { return 1.0 },
	}
}

// The point of the whole file: a bot that keeps failing becomes less willing to
// range far, and the row says why in words a human can read.
func TestRepeatedFailuresMakeABotMoreCautious(t *testing.T) {
	traits := &fakeTraits{}
	l := learner(repeat(Observation{POIID: "p1", Result: "failed", Reason: "unreachable"}, LearnAfterFailures), traits)

	if err := l.Observe(context.Background(), learnUUID); err != nil {
		t.Fatalf("Observe: %v", err)
	}
	if len(traits.writes) != 1 {
		t.Fatalf("%d writes, want 1", len(traits.writes))
	}
	w := traits.writes[0]
	if w.trait != TraitBoldness {
		t.Fatalf("wrote trait %q", w.trait)
	}
	if w.value >= 1.0 {
		t.Fatalf("boldness went to %v, want lower than the starting 1.0", w.value)
	}
	if w.reason == "" {
		t.Fatal("no reason recorded; an unexplained personality is undebuggable")
	}
}

// Without a counterweight every bot drifts to the floor, because failures are
// recorded and recoveries would not be. A system that can only lose confidence
// is decaying, not learning.
func TestSuccessesMakeABotBolderAgain(t *testing.T) {
	traits := &fakeTraits{}
	l := learner(repeat(Observation{POIID: "p1", Result: "completed"}, LearnAfterSuccesses), traits)

	if err := l.Observe(context.Background(), learnUUID); err != nil {
		t.Fatalf("Observe: %v", err)
	}
	if len(traits.writes) != 1 {
		t.Fatalf("%d writes, want 1", len(traits.writes))
	}
	if traits.writes[0].value <= 1.0 {
		t.Fatalf("boldness went to %v, want higher than 1.0", traits.writes[0].value)
	}
}

// A personality that swings on a bad afternoon is not a personality.
func TestOneBadTripChangesNothing(t *testing.T) {
	traits := &fakeTraits{}
	l := learner(repeat(Observation{POIID: "p1", Result: "failed", Reason: "unreachable"}, 1), traits)
	if err := l.Observe(context.Background(), learnUUID); err != nil {
		t.Fatalf("Observe: %v", err)
	}
	if len(traits.writes) != 0 {
		t.Fatalf("a single failure moved the bot: %+v", traits.writes)
	}
}

// Learning must need more evidence than merely avoiding one place: skipping a
// POI is cheap and reversible, changing who a bot is should not be.
func TestLearningNeedsMoreEvidenceThanAvoidingAPOI(t *testing.T) {
	if LearnAfterFailures <= DiscouragedThreshold {
		t.Fatalf("LearnAfterFailures=%d must exceed DiscouragedThreshold=%d",
			LearnAfterFailures, DiscouragedThreshold)
	}
}

// Outcomes that say nothing about the world must not reshape the bot either.
func TestNonEvidenceDoesNotChangeABot(t *testing.T) {
	traits := &fakeTraits{}
	l := learner(repeat(Observation{POIID: "p1", Result: "superseded"}, 20), traits)
	if err := l.Observe(context.Background(), learnUUID); err != nil {
		t.Fatalf("Observe: %v", err)
	}
	if len(traits.writes) != 0 {
		t.Fatalf("being re-targeted 20 times changed the bot: %+v", traits.writes)
	}
}

// Learning moves a bot within the range of possible bots, never outside it. A
// bot that learned its way to a travel range of zero would be broken, not shy.
func TestLearningStaysInsideTheBand(t *testing.T) {
	for _, tc := range []struct {
		name    string
		start   float64
		hist    []Observation
		wantNot float64
	}{
		{"already at the floor", BoldnessFloor,
			repeat(Observation{POIID: "p", Result: "failed", Reason: "unreachable"}, 50), BoldnessFloor},
		{"already at the ceiling", BoldnessCeiling,
			repeat(Observation{POIID: "p", Result: "completed"}, 50), BoldnessCeiling},
	} {
		t.Run(tc.name, func(t *testing.T) {
			traits := &fakeTraits{values: map[string]map[string]float64{
				learnUUID: {TraitBoldness: tc.start},
			}}
			l := learner(tc.hist, traits)
			if err := l.Observe(context.Background(), learnUUID); err != nil {
				t.Fatalf("Observe: %v", err)
			}
			// At a bound, the value cannot move, so nothing should be written:
			// churning the row would rewrite its reason for a change no reader
			// could see.
			if len(traits.writes) != 0 {
				t.Fatalf("wrote %+v while already at the bound", traits.writes)
			}
		})
	}
}

// Repeated adjustment must converge on the bound rather than march past it.
func TestManyAdjustmentsCannotEscapeTheBand(t *testing.T) {
	traits := &fakeTraits{values: map[string]map[string]float64{learnUUID: {TraitBoldness: 1.0}}}
	hist := repeat(Observation{POIID: "p", Result: "failed", Reason: "unreachable"}, LearnAfterFailures)
	l := learner(hist, traits)

	for i := 0; i < 100; i++ {
		if err := l.Observe(context.Background(), learnUUID); err != nil {
			t.Fatalf("Observe: %v", err)
		}
		if n := len(traits.writes); n > 0 {
			v := traits.writes[n-1].value
			if v < BoldnessFloor || v > BoldnessCeiling {
				t.Fatalf("boldness reached %v, outside [%v, %v]", v, BoldnessFloor, BoldnessCeiling)
			}
			traits.values[learnUUID][TraitBoldness] = v
		}
	}
}

// A bot with no stored trait must be nudged from the personality it was BORN
// with. Stepping from an assumed default would quietly erase the derived
// identity on the bot's first bad trip.
func TestFirstChangeStartsFromTheDerivedValue(t *testing.T) {
	traits := &fakeTraits{} // no stored values at all
	l := &Learner{
		Reader:  &fakeHistory{obs: repeat(Observation{POIID: "p", Result: "failed", Reason: "unreachable"}, LearnAfterFailures)},
		Traits:  traits,
		Values:  traits,
		Derived: func(string) float64 { return 1.4 },
	}
	if err := l.Observe(context.Background(), learnUUID); err != nil {
		t.Fatalf("Observe: %v", err)
	}
	if len(traits.writes) != 1 {
		t.Fatalf("%d writes, want 1", len(traits.writes))
	}
	// Compared with a tolerance, not for equality. `1.4-BoldnessStep` here is
	// CONSTANT arithmetic the compiler evaluates exactly, while the code adds two
	// float64s at runtime and lands on 1.3499999999999999. Asserting equality
	// between those two is a test that fails for a reason having nothing to do
	// with the behaviour it is checking.
	if got, want := traits.writes[0].value, 1.4-BoldnessStep; math.Abs(got-want) > 1e-9 {
		t.Fatalf("stepped to %v, want %v -- it did not start from the derived value", got, want)
	}
}

func TestHistoryFailureIsReportedAndChangesNothing(t *testing.T) {
	boom := errors.New("database is on fire")
	traits := &fakeTraits{}
	l := &Learner{Reader: &fakeHistory{err: boom}, Traits: traits, Values: traits}
	if err := l.Observe(context.Background(), learnUUID); !errors.Is(err, boom) {
		t.Fatalf("Observe returned %v, want %v", err, boom)
	}
	if len(traits.writes) != 0 {
		t.Fatal("a bot was changed on the strength of a failed read")
	}
}

// Every dependency absent is a supported configuration -- it is how the service
// runs without a database -- not a branch every caller must make.
func TestNilLearnerIsUsable(t *testing.T) {
	var l *Learner
	if err := l.Observe(context.Background(), learnUUID); err != nil {
		t.Fatalf("nil learner returned %v", err)
	}
	if err := (&Learner{}).Observe(context.Background(), learnUUID); err != nil {
		t.Fatalf("empty learner returned %v", err)
	}
}

func TestEmptyUUIDLearnsNothing(t *testing.T) {
	traits := &fakeTraits{}
	l := learner(repeat(Observation{POIID: "p", Result: "failed", Reason: "unreachable"}, 50), traits)
	if err := l.Observe(context.Background(), ""); err != nil {
		t.Fatalf("Observe: %v", err)
	}
	if len(traits.writes) != 0 {
		t.Fatal("wrote a trait against an empty uuid")
	}
}
