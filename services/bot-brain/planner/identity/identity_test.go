package identity

import (
	"fmt"
	"math"
	"testing"
)

// Realistic input: v4 UUIDs minted in one batch differ in only a few hex digits,
// which is exactly the case a weak hash would fail to separate.
func uuids(n int) []string {
	out := make([]string, n)
	for i := 0; i < n; i++ {
		out[i] = fmt.Sprintf("f47ac10b-58cc-4372-a567-%012x", i)
	}
	return out
}

// The whole design rests on this: traits are derived, never stored, so the same
// UUID must give the same answer in any process on any machine. If this is not
// true, a bot's personality changes when it moves between worldservers.
func TestDeriveIsDeterministic(t *testing.T) {
	for _, u := range uuids(64) {
		if a, b := Derive(u), Derive(u); a != b {
			t.Fatalf("Derive(%q) = %v then %v", u, a, b)
		}
	}
}

// An unminted bot must be indistinguishable from one before this package
// existed. Neutral has to scale the ceiling by exactly 1 and express no
// preference, or every bot without a UUID silently changes behaviour on deploy.
func TestEmptyUUIDIsExactlyNeutral(t *testing.T) {
	if got := Derive(""); got != Neutral {
		t.Fatalf("Derive(\"\") = %v, want %v", got, Neutral)
	}
	if got := Neutral.RangeScale(); got != 1 {
		t.Fatalf("Neutral.RangeScale() = %v, want exactly 1", got)
	}
	for _, id := range []string{"p1", "p2", "somewhere-else", ""} {
		if got := Affinity("", id); got != 0 {
			t.Fatalf("Affinity(\"\", %q) = %v, want 0", id, got)
		}
	}
}

// Boldness scales the travel ceiling, so a zero or negative multiplier would be
// a bot that can never go anywhere. Half to one-and-a-half is the intended band.
func TestBoldnessStaysInABand(t *testing.T) {
	for _, u := range uuids(512) {
		s := Derive(u).RangeScale()
		if s < 0.5 || s > 1.5 {
			t.Fatalf("Derive(%q).RangeScale() = %v, want [0.5, 1.5]", u, s)
		}
	}
}

// The point of hashing properly. Near-identical UUIDs must not produce
// near-identical bots, or a batch minted together behaves as one bot.
func TestNeighbouringUUIDsDoNotClump(t *testing.T) {
	const n = 256
	var buckets [10]int
	for _, u := range uuids(n) {
		b := int(Derive(u).Boldness * 10 / 2) // Boldness is [0.5,1.5] -> 10 buckets
		if b < 0 {
			b = 0
		}
		if b > 9 {
			b = 9
		}
		buckets[b]++
	}
	// Not a statistical test, just a clumping alarm: no single tenth of the
	// range may hold more than half the population.
	for i, c := range buckets {
		if c > n/2 {
			t.Fatalf("bucket %d holds %d of %d bots -- traits are clumping", i, c, n)
		}
	}
	distinct := 0
	for _, c := range buckets {
		if c > 0 {
			distinct++
		}
	}
	if distinct < 5 {
		t.Fatalf("only %d of 10 buckets used -- traits are clumping", distinct)
	}
}

// Affinity keys on the pair, not the bot: one bot always feels the same way
// about one place, and two bots disagree about the same place. The disagreement
// is what stops a crowd walking to the same POI in lockstep.
func TestAffinityIsPerBotAndPerPOI(t *testing.T) {
	const a, b = "f47ac10b-58cc-4372-a567-000000000001", "f47ac10b-58cc-4372-a567-000000000002"

	if x, y := Affinity(a, "p1"), Affinity(a, "p1"); x != y {
		t.Fatalf("Affinity is not stable: %v then %v", x, y)
	}
	if Affinity(a, "p1") == Affinity(b, "p1") {
		t.Fatal("two bots agree exactly on the same POI -- affinity is not per-bot")
	}
	if Affinity(a, "p1") == Affinity(a, "p2") {
		t.Fatal("one bot ranks two POIs identically -- affinity is not per-POI")
	}

	for _, u := range uuids(128) {
		if v := Affinity(u, "p1"); v < 0 || v >= 1 {
			t.Fatalf("Affinity(%q, p1) = %v, want [0, 1)", u, v)
		}
	}
}

// Two bots must actually disagree about which of two places to prefer, often
// enough to matter. If one POI wins for nearly everyone, the trait changes
// nothing in practice however well distributed it looks.
func TestBotsDisagreeAboutWhichPOIToPrefer(t *testing.T) {
	const n = 200
	firstWins := 0
	for _, u := range uuids(n) {
		if Affinity(u, "p1") > Affinity(u, "p2") {
			firstWins++
		}
	}
	if firstWins < n/4 || firstWins > 3*n/4 {
		t.Fatalf("p1 preferred by %d of %d bots -- preference is lopsided", firstWins, n)
	}
}

func TestUnitCoversTheRange(t *testing.T) {
	lo := unit([]byte{0, 0, 0, 0, 0, 0, 0, 0})
	hi := unit([]byte{255, 255, 255, 255, 255, 255, 255, 255})
	if lo != 0 {
		t.Fatalf("unit(min) = %v, want 0", lo)
	}
	if hi >= 1 || hi < 0.99 {
		t.Fatalf("unit(max) = %v, want just under 1", hi)
	}
	if math.IsNaN(lo) || math.IsNaN(hi) {
		t.Fatal("unit produced NaN")
	}
}
