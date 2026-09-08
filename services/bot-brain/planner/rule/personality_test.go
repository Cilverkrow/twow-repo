package rule_test

import (
	"context"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// planWithTraits runs one snapshot carrying personality keys and returns the
// intent. The UUID is left empty on purpose: Derive("") is Neutral, so boldness
// starts at exactly 1.0 and the only thing moving it is the keys.
func planWithTraits(t *testing.T, keys []string, maxYards float64, pois ...contract.PointOfInterest) contract.Intent {
	t.Helper()
	// Built from the defaults with only the ceiling replaced. rule.New swaps a
	// wholly-zero Thresholds for the defaults, so Thresholds{MaxTravelYards: 0}
	// does NOT mean "no limit" -- it means 1500.
	th := rule.DefaultThresholds()
	th.MaxTravelYards = maxYards
	s := base()
	s.Char.TraitKeys = keys
	s.POIs = pois
	p := rule.New(th)
	intents, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(intents) != 1 {
		t.Fatalf("intents = %d, want 1", len(intents))
	}
	return intents[0]
}

var (
	boldKeys     = []string{"curious", "risk_taking", "outdoorsy"}
	cautiousKeys = []string{"wary", "mistrustful", "wilderness_savvy"}
)

// The property this whole mapping exists for, and the one #235 used for derived
// identity: two bots in an IDENTICAL world state make different choices, with
// inference off.
//
// Before this, personality reached exactly one place -- a line of prompt text --
// so a deployment running rules-only had bots with elaborate personalities and
// no behaviour to show for them.
func TestPersonalityChangesTheChoiceWithInferenceOff(t *testing.T) {
	// 1100 sits between the two ceilings: 1000 * 1.24 for the bold bot and
	// 1000 * 0.76 for the cautious one.
	const maxYards = 1000
	far := poi("far", "grind_area", 1100)

	bold := planWithTraits(t, boldKeys, maxYards, far)
	if bold.Travel == nil || bold.Travel.POIID != "far" {
		t.Fatalf("the bold bot did not go: %+v", bold)
	}

	cautious := planWithTraits(t, cautiousKeys, maxYards, far)
	if cautious.Travel != nil {
		t.Fatalf("the cautious bot travelled to %q; the same POI the bold bot "+
			"chose is beyond its scaled range", cautious.Travel.POIID)
	}
}

// A bot with no personality must be unaffected, so shipping this changes nothing
// for the population until the worldserver starts assigning keys.
func TestABotWithoutPersonalityIsUnchanged(t *testing.T) {
	const maxYards = 1000
	for _, tc := range []struct {
		name string
		dist float64
		want bool
	}{
		{"inside the unscaled ceiling", 900, true},
		{"outside it", 1100, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := planWithTraits(t, nil, maxYards, poi("p", "grind_area", tc.dist))
			if (got.Travel != nil) != tc.want {
				t.Fatalf("travel=%v, want %v -- an unkeyed bot must use the "+
					"ceiling exactly as configured", got.Travel != nil, tc.want)
			}
		})
	}
}

// Conversational keys are the vast majority of the vocabulary. They must not
// move a bot at all, or every bot ends up with a travel range decided by traits
// about small talk.
func TestConversationalKeysDoNotMoveTheBot(t *testing.T) {
	const maxYards = 1000
	got := planWithTraits(t,
		[]string{"storyteller", "dry_humor", "hospitable", "scholarly", "fearless"},
		maxYards, poi("p", "grind_area", 1100))
	if got.Travel != nil {
		t.Fatalf("a bot with five conversational traits ranged past the ceiling "+
			"to %q", got.Travel.POIID)
	}
}

// The operator's bound stays the operator's: an explicitly disabled limit is
// disabled for everyone, and a cautious personality cannot reintroduce one.
func TestPersonalityCannotReenableADisabledLimit(t *testing.T) {
	got := planWithTraits(t, cautiousKeys, 0, poi("p", "grind_area", 100000))
	if got.Travel == nil {
		t.Fatal("a cautious bot was range-limited when the limit is disabled")
	}
}
