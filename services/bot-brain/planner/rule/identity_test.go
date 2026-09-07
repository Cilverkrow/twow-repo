package rule_test

import (
	"context"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// chooseGrind runs one snapshot through the planner and returns the POI it
// picked. grind_area is the bottom rung of the ladder, so a healthy bot with no
// quests lands there and the choice is purely about POI selection.
func chooseGrind(t *testing.T, uuid string, pois ...contract.PointOfInterest) string {
	t.Helper()
	s := base()
	s.Bot.UUID = uuid
	s.POIs = pois
	p := rule.New(rule.Thresholds{})
	intents, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(intents) != 1 {
		t.Fatalf("intents = %d, want 1", len(intents))
	}
	if intents[0].Travel == nil {
		t.Fatalf("no travel block in %+v", intents[0])
	}
	return intents[0].Travel.POIID
}

// The safety property that lets this ship without a migration: a bot whose UUID
// has not been minted yet must behave exactly as it did before traits existed --
// nearest first, ties broken by id.
func TestUnmintedBotStillTakesTheNearest(t *testing.T) {
	// Deliberately ordered so that "lowest id" and "nearest" disagree: if the
	// preference step leaked into the unminted path, it would return "aaa".
	got := chooseGrind(t, "",
		poi("zzz", "grind_area", 100),
		poi("aaa", "grind_area", 400),
	)
	if got != "zzz" {
		t.Fatalf("unminted bot chose %q, want the nearest %q", got, "zzz")
	}
}

// Personality must not look like a pathing bug. A POI far outside the
// comparable band is never traded away for a preferred one, whoever the bot is.
func TestAClearlyNearerPOIAlwaysWins(t *testing.T) {
	for _, u := range []string{
		"",
		"f47ac10b-58cc-4372-a567-000000000001",
		"f47ac10b-58cc-4372-a567-000000000002",
		"f47ac10b-58cc-4372-a567-000000000003",
		"f47ac10b-58cc-4372-a567-000000000004",
	} {
		got := chooseGrind(t, u,
			poi("near", "grind_area", 50),
			poi("far", "grind_area", 900),
		)
		if got != "near" {
			t.Fatalf("uuid %q chose %q over a much nearer POI", u, got)
		}
	}
}

// The Phase 1 criterion, as a test: two bots with identical state and identical
// candidates, differing only in identity, do not make identical choices.
//
// Before traits this was impossible -- the planner is deterministic on state
// alone, so a crowd of bots in one spot walked to one POI together.
func TestTwoIdenticalBotsWithDifferentIdentitiesDiverge(t *testing.T) {
	// Two candidates close enough to be comparable (within the 25% band).
	a := poi("alpha", "grind_area", 300)
	b := poi("bravo", "grind_area", 330)

	seen := map[string]int{}
	for i := 0; i < 64; i++ {
		u := uuidN(i)
		seen[chooseGrind(t, u, a, b)]++
	}
	if len(seen) < 2 {
		t.Fatalf("64 different bots all chose the same POI: %v", seen)
	}
	for id, n := range seen {
		if n == 0 {
			t.Fatalf("POI %q never chosen", id)
		}
	}
}

// Same bot, same input, same answer -- every time. The planner's determinism
// guarantee must survive traits, or replaying a request stops being meaningful.
func TestChoiceIsStableForOneBot(t *testing.T) {
	const u = "f47ac10b-58cc-4372-a567-00000000002a"
	a := poi("alpha", "grind_area", 300)
	b := poi("bravo", "grind_area", 330)

	first := chooseGrind(t, u, a, b)
	for i := 0; i < 16; i++ {
		if got := chooseGrind(t, u, a, b); got != first {
			t.Fatalf("run %d chose %q, first run chose %q", i, got, first)
		}
	}
}

// Boldness scales the travel ceiling, so the set of reachable POIs is per-bot.
// A destination just past the configured limit is out of reach for a homebound
// bot and in reach for a bold one -- and no bot may exceed the limit by more
// than the intended half.
func TestBoldnessMovesTheTravelCeiling(t *testing.T) {
	// The ceiling is 1500 by default, so this is reachable only with a scale
	// above ~1.2, and unreachable for anyone below it.
	far := poi("far", "grind_area", 1800)

	reached, refused := 0, 0
	for i := 0; i < 128; i++ {
		s := base()
		s.Bot.UUID = uuidN(i)
		s.POIs = []contract.PointOfInterest{far}
		p := rule.New(rule.Thresholds{})
		intents, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
		if err != nil {
			t.Fatalf("Plan: %v", err)
		}
		if len(intents) == 1 && intents[0].Travel != nil && intents[0].Travel.POIID == "far" {
			reached++
		} else {
			refused++
		}
	}
	if reached == 0 {
		t.Fatal("no bot was bold enough to reach a POI at 1800y (ceiling 1500y)")
	}
	if refused == 0 {
		t.Fatal("every bot reached 1800y -- the ceiling is no longer a bound")
	}

	// Nobody may exceed 1500 * 1.5 = 2250.
	tooFar := poi("beyond", "grind_area", 2400)
	for i := 0; i < 128; i++ {
		s := base()
		s.Bot.UUID = uuidN(i)
		s.POIs = []contract.PointOfInterest{tooFar}
		p := rule.New(rule.Thresholds{})
		intents, _ := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
		if len(intents) == 1 && intents[0].Travel != nil && intents[0].Travel.POIID == "beyond" {
			t.Fatalf("bot %d travelled 2400y, past the hard bound of 1500*1.5", i)
		}
	}
}

// Disabling the limit must stay disabled for everyone: scaling zero is still
// zero, not a per-bot ceiling reintroduced by the back door.
func TestZeroCeilingStaysDisabledForEveryone(t *testing.T) {
	for i := 0; i < 16; i++ {
		s := base()
		s.Bot.UUID = uuidN(i)
		s.POIs = []contract.PointOfInterest{poi("miles", "grind_area", 50000)}
		p := rule.New(rule.Thresholds{
			RestBelowHealthPct:           45,
			RepairBelowDurabilityPct:     25,
			VendorWhenFreeBagSlotsAtMost: 1,
			MaxTravelYards:               0,
		})
		intents, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
		if err != nil {
			t.Fatalf("Plan: %v", err)
		}
		if len(intents) != 1 || intents[0].Travel == nil || intents[0].Travel.POIID != "miles" {
			t.Fatalf("bot %d did not reach a POI with the ceiling disabled: %+v", i, intents)
		}
	}
}

func uuidN(i int) string {
	const hex = "0123456789abcdef"
	out := []byte("f47ac10b-58cc-4372-a567-000000000000")
	out[len(out)-1] = hex[i&0xf]
	out[len(out)-2] = hex[(i>>4)&0xf]
	out[len(out)-3] = hex[(i>>8)&0xf]
	return string(out)
}
