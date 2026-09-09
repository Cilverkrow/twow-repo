package rule_test

import (
	"context"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// plan runs the planner over one snapshot and splits what came back into the
// bot's errand and its standing condition, which is how the server reads it:
// two slots, filled independently, neither able to evict the other.
func plan(t *testing.T, s contract.Snapshot) (errand contract.Intent, standing *contract.Intent) {
	t.Helper()
	intents, err := rule.New(rule.Thresholds{}).Plan(context.Background(), planner.Request{
		Snapshots:   []contract.Snapshot{s},
		ServerNowMS: 1_700_000_000_000,
		IntentTTLMS: 30_000,
	})
	if err != nil {
		t.Fatalf("Plan returned an error: %v", err)
	}
	for i := range intents {
		if intents[i].Kind == contract.IntentSetStrategies {
			if standing != nil {
				t.Fatalf("two set_strategies for one bot; a bot has one strategy set, not several")
			}
			standing = &intents[i]
			continue
		}
		errand = intents[i]
	}
	return errand, standing
}

// The placeholder policy, both halves. The ASSERT half is the easy one to get
// right and the easy one to over-read; the RELEASE half is what stops a brain
// from leaving a bot permanently missing a behaviour after the policy that
// suppressed it has moved on, and it is expressed by naming nothing rather than
// by sending nothing.
func TestSetStrategiesRidesAlongsideTheErrand(t *testing.T) {
	broken := base()
	broken.Vit.DurabilityPct = f(10)
	broken.POIs = []contract.PointOfInterest{poi("r1", "repair", 30)}

	errand, standing := plan(t, broken)
	if errand.Kind != contract.IntentRepair {
		t.Fatalf("errand kind = %q, want %q", errand.Kind, contract.IntentRepair)
	}
	if standing == nil {
		t.Fatal("no set_strategies alongside the repair errand; the whole point is that it does not evict the errand")
	}
	if standing.Bot != errand.Bot {
		t.Errorf("set_strategies bot = %v, want the errand's bot %v", standing.Bot, errand.Bot)
	}
	// Distinct ids, because outcomes are attributed by intent id and the two
	// intents end in different ways at different times.
	if standing.IntentID == errand.IntentID {
		t.Errorf("both intents share intent_id %q; outcomes could not be told apart", standing.IntentID)
	}
	if standing.ExpiresAtMS != 1_700_000_030_000 {
		t.Errorf("expiry = %d, want server clock + TTL; a standing intent is as perishable as any other",
			standing.ExpiresAtMS)
	}
	if standing.Strategies == nil || len(standing.Strategies.Changes) != 1 {
		t.Fatalf("strategies = %+v, want exactly one change", standing.Strategies)
	}
	// One name, one state, and disable. The brain owns what it names and
	// nothing else: everything unnamed stays as AiFactory built it.
	change := standing.Strategies.Changes[0]
	if change.Name != "grind" || change.State != contract.BotStateNonCombat || change.Enable {
		t.Errorf("change = %+v, want grind/non_combat/disable", change)
	}
	if err := standing.Validate(); err != nil {
		t.Errorf("the standing intent must pass Validate(), got: %v", err)
	}
}

func TestSetStrategiesReleasesByNamingNothing(t *testing.T) {
	// Full bags is the other errand rung, so it asserts.
	bags := base()
	bags.Char.FreeBagSlots = 0
	bags.POIs = []contract.PointOfInterest{poi("v1", "vendor", 20)}
	if _, standing := plan(t, bags); standing == nil {
		t.Fatal("vendor errand produced no set_strategies")
	}

	// And every rung that is not an errand names nothing at all. That is the
	// release: the server hands "grind" back to what it was on an answer that
	// names no strategies. Emitting "+grind" instead would be the brain
	// claiming ownership of a strategy AiFactory may deliberately never have
	// given this bot.
	for _, tc := range []struct {
		name   string
		mutate func(*contract.Snapshot)
	}{
		{"idle", func(*contract.Snapshot) {}},
		{"rest", func(s *contract.Snapshot) { s.Vit.HealthPct = 20 }},
		{"grind_area", func(s *contract.Snapshot) {
			s.POIs = []contract.PointOfInterest{poi("g1", "grind_area", 50)}
		}},
		{"in combat", func(s *contract.Snapshot) { s.Vit.InCombat = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := base()
			tc.mutate(&s)
			if _, standing := plan(t, s); standing != nil {
				t.Errorf("got a set_strategies (%+v) off an errand; the brain must give the strategy back",
					standing.Strategies)
			}
		})
	}
}
