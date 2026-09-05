package rule_test

import (
	"context"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

func f(v float64) *float64 { return &v }

func base() contract.Snapshot {
	return contract.Snapshot{
		Bot:  contract.BotID{Realm: 1, GUID: 1},
		Char: contract.Character{Name: "Bot", Level: 20, Class: 1, Race: 1, Faction: "alliance", FreeBagSlots: 12},
		Pos:  contract.Position{MapID: 0, X: 100, Y: 100, Z: 10},
		Vit:  contract.Vitals{HealthPct: 100, DurabilityPct: f(90)},
		Around: contract.Surroundings{
			GroupSize: 1,
		},
	}
}

func poi(id, kind string, dist float64) contract.PointOfInterest {
	return contract.PointOfInterest{
		ID: id, Kind: kind, Pos: contract.Position{MapID: 0}, DistanceYards: f(dist),
	}
}

func TestRuleLadder(t *testing.T) {
	tests := []struct {
		name     string
		mutate   func(*contract.Snapshot)
		wantKind contract.IntentKind
		wantPOI  string
		why      string
	}{
		{
			name:     "healthy bot with nothing offered idles",
			mutate:   func(*contract.Snapshot) {},
			wantKind: contract.IntentIdle,
			why:      "idle is always available and is never wrong, only unambitious",
		},
		{
			name: "dead bot idles; recovery is tier 0",
			mutate: func(s *contract.Snapshot) {
				s.Vit.IsDead = true
				s.POIs = []contract.PointOfInterest{poi("v1", "vendor", 10)}
			},
			wantKind: contract.IntentIdle,
		},
		{
			name: "bot in combat idles",
			mutate: func(s *contract.Snapshot) {
				s.Vit.InCombat = true
				s.POIs = []contract.PointOfInterest{poi("v1", "vendor", 10)}
			},
			wantKind: contract.IntentIdle,
		},
		{
			name: "bot inside an instance idles",
			mutate: func(s *contract.Snapshot) {
				s.Pos.InstanceID = 42
				s.POIs = []contract.PointOfInterest{poi("v1", "vendor", 10)}
			},
			wantKind: contract.IntentIdle,
		},
		{
			name: "group follower idles rather than earning a rejection",
			mutate: func(s *contract.Snapshot) {
				s.Around.GroupSize = 5
				s.Around.IsGroupLeader = false
				s.POIs = []contract.PointOfInterest{poi("g1", "grind_area", 50)}
			},
			wantKind: contract.IntentIdle,
		},
		{
			name: "group leader may still travel",
			mutate: func(s *contract.Snapshot) {
				s.Around.GroupSize = 5
				s.Around.IsGroupLeader = true
				s.POIs = []contract.PointOfInterest{poi("g1", "grind_area", 50)}
			},
			wantKind: contract.IntentGrindArea,
			wantPOI:  "g1",
		},
		{
			name: "low durability outranks everything else",
			mutate: func(s *contract.Snapshot) {
				s.Vit.DurabilityPct = f(5)
				s.Char.FreeBagSlots = 0
				s.POIs = []contract.PointOfInterest{poi("r1", "repair", 80), poi("v1", "vendor", 10)}
			},
			wantKind: contract.IntentRepair,
			wantPOI:  "r1",
			why:      "a bot that cannot fight is worth fixing before it is worth directing",
		},
		{
			name: "low durability with no repair POI falls through",
			mutate: func(s *contract.Snapshot) {
				s.Vit.DurabilityPct = f(5)
				s.POIs = []contract.PointOfInterest{poi("g1", "grind_area", 20)}
			},
			wantKind: contract.IntentGrindArea,
			wantPOI:  "g1",
		},
		{
			name: "absent durability is not read as low",
			mutate: func(s *contract.Snapshot) {
				s.Vit.DurabilityPct = nil
				s.POIs = []contract.PointOfInterest{poi("r1", "repair", 10), poi("g1", "grind_area", 20)}
			},
			wantKind: contract.IntentGrindArea,
			wantPOI:  "g1",
			why:      "absence must never be read as zero",
		},
		{
			name: "full bags send the bot to a vendor",
			mutate: func(s *contract.Snapshot) {
				s.Char.FreeBagSlots = 0
				s.POIs = []contract.PointOfInterest{poi("v1", "vendor", 300), poi("g1", "grind_area", 5)}
			},
			wantKind: contract.IntentVendorSell,
			wantPOI:  "v1",
		},
		{
			name: "hurt bot rests",
			mutate: func(s *contract.Snapshot) {
				s.Vit.HealthPct = 20
				s.POIs = []contract.PointOfInterest{poi("g1", "grind_area", 5)}
			},
			wantKind: contract.IntentRest,
		},
		{
			name: "complete quest is handed in before new work is picked up",
			mutate: func(s *contract.Snapshot) {
				s.Quests = []contract.QuestEntry{{QuestID: 77, Status: "complete"}}
				s.POIs = []contract.PointOfInterest{
					{ID: "t1", Kind: "quest_turnin", Pos: contract.Position{MapID: 0}, DistanceYards: f(400), RelatedQuestID: 77},
					poi("q1", "quest_giver", 5),
				}
			},
			wantKind: contract.IntentTurnInQuest,
			wantPOI:  "t1",
		},
		{
			name: "a turn-in POI for a quest not in the log is ignored",
			mutate: func(s *contract.Snapshot) {
				s.Quests = []contract.QuestEntry{{QuestID: 1, Status: "incomplete"}}
				s.POIs = []contract.PointOfInterest{
					{ID: "t1", Kind: "quest_turnin", Pos: contract.Position{MapID: 0}, DistanceYards: f(10), RelatedQuestID: 999},
					poi("g1", "grind_area", 90),
				}
			},
			wantKind: contract.IntentGrindArea,
			wantPOI:  "g1",
		},
		{
			name: "incomplete quest objective is pursued",
			mutate: func(s *contract.Snapshot) {
				s.Quests = []contract.QuestEntry{{QuestID: 5, Status: "incomplete", ObjectivesDone: 2, ObjectivesTotal: 10}}
				s.POIs = []contract.PointOfInterest{
					{ID: "o1", Kind: "quest_objective", Pos: contract.Position{MapID: 0}, DistanceYards: f(200), RelatedQuestID: 5},
					poi("q1", "quest_giver", 5),
				}
			},
			wantKind: contract.IntentTravelTo,
			wantPOI:  "o1",
		},
		{
			name: "empty log picks up new work",
			mutate: func(s *contract.Snapshot) {
				s.POIs = []contract.PointOfInterest{poi("q1", "quest_giver", 60), poi("g1", "grind_area", 10)}
			},
			wantKind: contract.IntentPickQuest,
			wantPOI:  "q1",
		},
		{
			name: "nearest POI of a kind wins",
			mutate: func(s *contract.Snapshot) {
				s.POIs = []contract.PointOfInterest{poi("far", "grind_area", 900), poi("near", "grind_area", 40)}
			},
			wantKind: contract.IntentGrindArea,
			wantPOI:  "near",
		},
		{
			name: "an unpathed POI sorts last, not first",
			mutate: func(s *contract.Snapshot) {
				s.POIs = []contract.PointOfInterest{
					{ID: "unpathed", Kind: "grind_area", Pos: contract.Position{MapID: 0}},
					poi("pathed", "grind_area", 800),
				}
			},
			wantKind: contract.IntentGrindArea,
			wantPOI:  "pathed",
			why:      "distance unknown must not sort as distance zero",
		},
		{
			name: "POIs beyond the travel cap are not proposed",
			mutate: func(s *contract.Snapshot) {
				s.POIs = []contract.PointOfInterest{poi("g1", "grind_area", 99999)}
			},
			wantKind: contract.IntentIdle,
		},
		{
			name: "a POI on another map is refused rather than compared",
			mutate: func(s *contract.Snapshot) {
				s.POIs = []contract.PointOfInterest{
					{ID: "kalimdor", Kind: "grind_area", Pos: contract.Position{MapID: 1}, DistanceYards: f(1)},
				}
			},
			wantKind: contract.IntentIdle,
			why:      "coordinates on different maps are not comparable",
		},
		{
			name: "an unknown POI kind is ignored, not rejected",
			mutate: func(s *contract.Snapshot) {
				s.POIs = []contract.PointOfInterest{
					{ID: "x", Kind: "auction_house_from_a_future_version", Pos: contract.Position{MapID: 0}, DistanceYards: f(1)},
				}
			},
			wantKind: contract.IntentIdle,
		},
	}

	p := rule.New(rule.Thresholds{})
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := base()
			tc.mutate(&s)
			intents, err := p.Plan(context.Background(), planner.Request{
				Snapshots:   []contract.Snapshot{s},
				ServerNowMS: 1_700_000_000_000,
				IntentTTLMS: 30_000,
			})
			if err != nil {
				t.Fatalf("Plan returned an error: %v", err)
			}
			if len(intents) != 1 {
				t.Fatalf("got %d intents, want exactly 1 (the rule planner always answers)", len(intents))
			}
			got := intents[0]
			if got.Kind != tc.wantKind {
				t.Fatalf("kind = %q, want %q (%s); rationale was %q", got.Kind, tc.wantKind, tc.why, got.Rationale)
			}
			if tc.wantPOI != "" {
				if got.Travel == nil || got.Travel.POIID != tc.wantPOI {
					t.Fatalf("poi = %+v, want %q", got.Travel, tc.wantPOI)
				}
			}
			if got.ExpiresAtMS != 1_700_000_030_000 {
				t.Errorf("expiry = %d, want server clock + TTL = 1700000030000", got.ExpiresAtMS)
			}
			if got.Source != "rule" {
				t.Errorf("source = %q, want %q", got.Source, "rule")
			}
			if err := got.Validate(); err != nil {
				t.Errorf("planner emitted an invalid intent: %v", err)
			}
		})
	}
}

// The same snapshot must always produce the same decision. Two replicas
// planning the same bot that disagreed would make behaviour depend on which pod
// answered.
func TestRulePlannerIsDeterministic(t *testing.T) {
	s := base()
	s.POIs = []contract.PointOfInterest{
		{ID: "b", Kind: "grind_area", Pos: contract.Position{MapID: 0}, DistanceYards: f(100)},
		{ID: "a", Kind: "grind_area", Pos: contract.Position{MapID: 0}, DistanceYards: f(100)},
	}
	p := rule.New(rule.Thresholds{})
	req := planner.Request{Snapshots: []contract.Snapshot{s}}
	first, _ := p.Plan(context.Background(), req)
	for i := 0; i < 50; i++ {
		got, _ := p.Plan(context.Background(), req)
		if got[0].Kind != first[0].Kind || got[0].Travel.POIID != first[0].Travel.POIID {
			t.Fatalf("run %d disagreed: %v/%v vs %v/%v",
				i, got[0].Kind, got[0].Travel.POIID, first[0].Kind, first[0].Travel.POIID)
		}
	}
	if first[0].Travel.POIID != "a" {
		t.Fatalf("tie broke on %q, want %q (ties must break on the id so replicas agree)", first[0].Travel.POIID, "a")
	}
}

// Every snapshot in a batch gets exactly one answer, including malformed ones,
// which get idle rather than nothing.
func TestRulePlannerAnswersWholeBatch(t *testing.T) {
	batch := make([]contract.Snapshot, 500)
	for i := range batch {
		batch[i] = base()
		batch[i].Bot.GUID = uint64(i + 1)
	}
	// One malformed entry in the middle.
	batch[250].Char.Level = 0

	p := rule.New(rule.Thresholds{})
	intents, err := p.Plan(context.Background(), planner.Request{Snapshots: batch})
	if err != nil {
		t.Fatalf("Plan returned an error: %v", err)
	}
	if len(intents) != len(batch) {
		t.Fatalf("got %d intents for %d snapshots", len(intents), len(batch))
	}
	if intents[250].Kind != contract.IntentIdle {
		t.Fatalf("malformed snapshot produced %q, want idle", intents[250].Kind)
	}
	for i, in := range intents {
		if in.Bot != batch[i].Bot {
			t.Fatalf("intent %d addressed to %s, want %s (order must follow the batch)", i, in.Bot, batch[i].Bot)
		}
	}
}

func TestRulePlannerHonoursCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	p := rule.New(rule.Thresholds{})
	_, err := p.Plan(ctx, planner.Request{Snapshots: []contract.Snapshot{base()}})
	if err == nil {
		t.Fatal("expected a cancellation error")
	}
}

func TestRulePlannerIsAlwaysReady(t *testing.T) {
	if !rule.New(rule.Thresholds{}).Ready() {
		t.Fatal("the rule planner must always be ready; the whole design leans on that")
	}
}

func TestCustomThresholds(t *testing.T) {
	// Disable the rest rung and the bot should travel instead of resting.
	p := rule.New(rule.Thresholds{
		RestBelowHealthPct:           0,
		RepairBelowDurabilityPct:     25,
		VendorWhenFreeBagSlotsAtMost: 1,
		MaxTravelYards:               1500,
	})
	s := base()
	s.Vit.HealthPct = 5
	s.POIs = []contract.PointOfInterest{poi("g1", "grind_area", 10)}
	intents, _ := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
	if intents[0].Kind != contract.IntentGrindArea {
		t.Fatalf("kind = %q, want grind_area with the rest rung disabled", intents[0].Kind)
	}
}

// The outcome loop: a destination the server refused must not be chosen again.
//
// Before this, RecordOutcome had one call site and it passed "accepted", so the
// planner heard about successes only. A bot whose travel was refused was sent to
// the same POI on the next tick, and the next, indefinitely.
func TestRefusedPOIIsNotChosenAgain(t *testing.T) {
	reasons := []string{"unreachable", "unknown_poi", "stale_poi"}
	for _, reason := range reasons {
		t.Run(reason, func(t *testing.T) {
			s := base()
			s.POIs = []contract.PointOfInterest{
				{ID: "near", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(10)},
				{ID: "far", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(500)},
			}
			s.LastOutcome = &contract.IntentOutcome{
				IntentID: "prev", Kind: contract.IntentTravelTo,
				Result: "rejected", Reason: reason, POIID: "near",
			}

			got := planOne(t, s)
			if got.Travel == nil {
				t.Fatalf("no travel intent at all; the planner gave up instead of choosing elsewhere (kind %q)", got.Kind)
			}
			if got.Travel.POIID == "near" {
				t.Fatalf("re-proposed %q after it was refused with %q; this is the loop the outcome exists to break",
					got.Travel.POIID, reason)
			}
			if got.Travel.POIID != "far" {
				t.Fatalf("POI = %q, want the remaining candidate %q", got.Travel.POIID, "far")
			}
		})
	}
}

// Reasons that are about the BOT or the KIND, not the place, must NOT steer the
// planner away from a perfectly good destination.
func TestOutcomeReasonsThatAreNotAboutThePlace(t *testing.T) {
	for _, reason := range []string{"in_combat", "not_group_leader", "unsupported_kind", "identity_protected", "some_future_reason"} {
		t.Run(reason, func(t *testing.T) {
			s := base()
			s.POIs = []contract.PointOfInterest{
				{ID: "near", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(10)},
			}
			s.LastOutcome = &contract.IntentOutcome{
				IntentID: "prev", Kind: contract.IntentTravelTo,
				Result: "rejected", Reason: reason, POIID: "near",
			}
			got := planOne(t, s)
			if got.Travel == nil || got.Travel.POIID != "near" {
				t.Fatalf("avoided %q because of %q, which says nothing about the destination; superstition, not feedback", "near", reason)
			}
		})
	}
}

// "expired" is not a verdict on the destination. Nothing was wrong with the
// place - the plan arrived too late to apply. Treating it as "choose elsewhere"
// would walk bots away from good destinations whenever the service was busy.
func TestExpiredDoesNotAvoidThePOI(t *testing.T) {
	s := base()
	s.POIs = []contract.PointOfInterest{
		{ID: "near", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(10)},
	}
	s.LastOutcome = &contract.IntentOutcome{
		IntentID: "prev", Kind: contract.IntentTravelTo,
		Result: "expired", POIID: "near",
	}
	got := planOne(t, s)
	if got.Travel == nil || got.Travel.POIID != "near" {
		t.Fatal("an expired intent steered the planner away from its destination; expiry is a timing fact, not a routing one")
	}
}

// Successes must not be read as refusals.
func TestAcceptedOutcomeDoesNotAvoid(t *testing.T) {
	for _, result := range []string{"accepted", "completed", "superseded"} {
		t.Run(result, func(t *testing.T) {
			s := base()
			s.POIs = []contract.PointOfInterest{
				{ID: "near", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(10)},
			}
			s.LastOutcome = &contract.IntentOutcome{
				IntentID: "prev", Kind: contract.IntentTravelTo, Result: result, POIID: "near",
			}
			got := planOne(t, s)
			if got.Travel == nil || got.Travel.POIID != "near" {
				t.Fatalf("result %q was treated as a refusal", result)
			}
		})
	}
}

// A refusal with no POI id (an older server) must not silently avoid nothing in
// a way that breaks, and must not panic.
func TestRefusalWithoutPOIIDIsHarmless(t *testing.T) {
	s := base()
	s.POIs = []contract.PointOfInterest{
		{ID: "near", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(10)},
	}
	s.LastOutcome = &contract.IntentOutcome{
		IntentID: "prev", Kind: contract.IntentTravelTo, Result: "rejected", Reason: "unreachable",
	}
	got := planOne(t, s)
	if got.Travel == nil || got.Travel.POIID != "near" {
		t.Fatal("an outcome with no poi_id changed the choice; empty must mean unknown, not a match")
	}
}

// Absence of an outcome is normal - a bot never planned for, or one whose
// history the server lost across a restart - and must never read as failure.
func TestNoOutcomeIsNotAFailure(t *testing.T) {
	s := base()
	s.POIs = []contract.PointOfInterest{
		{ID: "near", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(10)},
	}
	s.LastOutcome = nil
	got := planOne(t, s)
	if got.Travel == nil || got.Travel.POIID != "near" {
		t.Fatal("a bot with no history was refused a destination")
	}
}

// When the ONLY candidate is the refused one, the planner must not propose it
// anyway. Skipping rather than penalising is the point: a penalty still chooses
// it when it is alone, which is exactly the case that loops.
func TestRefusedSoleCandidateIsNotProposed(t *testing.T) {
	s := base()
	s.POIs = []contract.PointOfInterest{
		{ID: "only", Kind: "grind_area", Pos: s.Pos, DistanceYards: f(10)},
	}
	s.LastOutcome = &contract.IntentOutcome{
		IntentID: "prev", Kind: contract.IntentTravelTo,
		Result: "rejected", Reason: "unreachable", POIID: "only",
	}
	got := planOne(t, s)
	if got.Travel != nil && got.Travel.POIID == "only" {
		t.Fatal("proposed the sole candidate again after it was refused; this is the infinite loop")
	}
}

func planOne(t *testing.T, s contract.Snapshot) contract.Intent {
	t.Helper()
	p := rule.New(rule.DefaultThresholds())
	out, err := p.Plan(context.Background(), planner.Request{
		Snapshots:   []contract.Snapshot{s},
		ServerNowMS: 1_756_700_000_000,
		IntentTTLMS: 30_000,
	})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("got %d intents, want 1", len(out))
	}
	return out[0]
}
