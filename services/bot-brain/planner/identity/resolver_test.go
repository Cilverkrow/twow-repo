package identity

import (
	"context"
	"errors"
	"math"
	"testing"
)

type fakeStore struct {
	data map[string]map[string]float64
	err  error
	got  []string
}

func (f *fakeStore) Load(_ context.Context, uuids []string) (map[string]map[string]float64, error) {
	f.got = append([]string(nil), uuids...)
	if f.err != nil {
		return nil, f.err
	}
	return f.data, nil
}

const (
	uuidA = "f47ac10b-58cc-4372-a567-00000000000a"
	uuidB = "f47ac10b-58cc-4372-a567-00000000000b"
)

// A nil resolver and a nil store are both supported: this is how the service
// runs before a database is configured, and it must be a normal mode rather than
// a crash.
func TestNilResolverStillDerives(t *testing.T) {
	var r *Resolver
	got := r.Resolve(context.Background(), []string{uuidA})
	if got[uuidA] != Derive(uuidA) {
		t.Fatalf("nil resolver gave %v, want the derived %v", got[uuidA], Derive(uuidA))
	}

	r2 := &Resolver{}
	got = r2.Resolve(context.Background(), []string{uuidA})
	if got[uuidA] != Derive(uuidA) {
		t.Fatalf("nil store gave %v, want the derived %v", got[uuidA], Derive(uuidA))
	}
}

// The property the whole design rests on: a store that is down makes bots
// generic, not broken. If this regresses, a database blip stops every bot from
// being planned for.
func TestStoreFailureFallsBackToDerived(t *testing.T) {
	boom := errors.New("database is on fire")
	var reported error
	r := &Resolver{
		Store:        &fakeStore{err: boom},
		OnStoreError: func(err error) { reported = err },
	}

	got := r.Resolve(context.Background(), []string{uuidA, uuidB})
	if len(got) != 2 {
		t.Fatalf("got %d entries, want 2 -- every bot must get traits", len(got))
	}
	if got[uuidA] != Derive(uuidA) || got[uuidB] != Derive(uuidB) {
		t.Fatal("a store failure changed the traits instead of falling back")
	}
	if !errors.Is(reported, boom) {
		t.Fatalf("OnStoreError got %v, want %v", reported, boom)
	}
}

// A bot that has lived overrides the bot it was born as.
func TestStoredValueWinsOverDerived(t *testing.T) {
	r := &Resolver{Store: &fakeStore{data: map[string]map[string]float64{
		uuidA: {TraitBoldness: 1.4},
	}}}

	got := r.Resolve(context.Background(), []string{uuidA, uuidB})
	if got[uuidA].Boldness != 1.4 {
		t.Fatalf("stored boldness = %v, want 1.4", got[uuidA].Boldness)
	}
	// The bot with no row is untouched -- absence means "not changed yet".
	if got[uuidB] != Derive(uuidB) {
		t.Fatalf("bot without a row = %v, want derived %v", got[uuidB], Derive(uuidB))
	}
}

// The operator's bound stays the operator's bound. A hand-written row, or a
// future learning rule with a bug, must not be able to give one bot a travel
// range of zero or ten times the ceiling.
func TestStoredValuesAreClamped(t *testing.T) {
	for _, tc := range []struct {
		name  string
		value float64
		want  float64
	}{
		{"far above the band", 99, boldnessMax},
		{"far below the band", -5, boldnessMin},
		{"zero is not a bot that cannot move", 0, boldnessMin},
		{"inside the band is untouched", 1.1, 1.1},
		{"positive infinity", math.Inf(1), boldnessMax},
		{"negative infinity", math.Inf(-1), boldnessMin},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &Resolver{Store: &fakeStore{data: map[string]map[string]float64{
				uuidA: {TraitBoldness: tc.value},
			}}}
			if got := r.Resolve(context.Background(), []string{uuidA})[uuidA].Boldness; got != tc.want {
				t.Fatalf("stored %v resolved to %v, want %v", tc.value, got, tc.want)
			}
		})
	}
}

// NaN compares false against everything, so a naive bounds check passes it
// straight through -- and it would then poison every distance comparison it
// reached. It must not survive.
func TestNaNDoesNotSurvive(t *testing.T) {
	r := &Resolver{Store: &fakeStore{data: map[string]map[string]float64{
		uuidA: {TraitBoldness: math.NaN()},
	}}}
	got := r.Resolve(context.Background(), []string{uuidA})[uuidA].Boldness
	if math.IsNaN(got) {
		t.Fatal("NaN reached the planner")
	}
	if got < boldnessMin || got > boldnessMax {
		t.Fatalf("NaN resolved to %v, outside the band", got)
	}
}

// The vocabulary is enforced in the reader, because the schema deliberately does
// not constrain the trait name. A typo must be dropped, never guessed at: a bot
// whose personality depends on a spelling mistake is worse than one with none.
func TestUnknownTraitNamesAreIgnored(t *testing.T) {
	r := &Resolver{Store: &fakeStore{data: map[string]map[string]float64{
		uuidA: {"boldnes": 1.5, "BOLDNESS": 0.5, "courage": 1.5},
	}}}
	if got, want := r.Resolve(context.Background(), []string{uuidA})[uuidA], Derive(uuidA); got != want {
		t.Fatalf("an unknown trait name changed the bot: %v, want %v", got, want)
	}
}

// Rows for bots nobody asked about must not widen the result. The caller
// allocated for what it requested, and leaking one batch's rows into another's
// answer would be a bug that only shows up under load.
func TestRowsForUnrequestedBotsAreIgnored(t *testing.T) {
	r := &Resolver{Store: &fakeStore{data: map[string]map[string]float64{
		uuidB: {TraitBoldness: 1.4},
		"":    {TraitBoldness: 1.4},
	}}}
	got := r.Resolve(context.Background(), []string{uuidA})
	if len(got) != 1 {
		t.Fatalf("result has %d entries, want only the 1 requested: %v", len(got), got)
	}
	if _, ok := got[uuidB]; ok {
		t.Fatal("an unrequested bot appeared in the result")
	}
}

// An unminted bot stays neutral even if the store somehow holds a row keyed on
// the empty string.
func TestEmptyUUIDStaysNeutral(t *testing.T) {
	r := &Resolver{Store: &fakeStore{data: map[string]map[string]float64{
		"": {TraitBoldness: 1.5},
	}}}
	if got := r.Resolve(context.Background(), []string{""})[""]; got != Neutral {
		t.Fatalf("empty uuid resolved to %v, want %v", got, Neutral)
	}
}

func TestEveryRequestedUUIDGetsAnEntry(t *testing.T) {
	r := &Resolver{Store: &fakeStore{data: map[string]map[string]float64{}}}
	uuids := []string{uuidA, uuidB, "", uuidA}
	got := r.Resolve(context.Background(), uuids)
	for _, u := range uuids {
		if _, ok := got[u]; !ok {
			t.Fatalf("uuid %q has no entry", u)
		}
	}
}
