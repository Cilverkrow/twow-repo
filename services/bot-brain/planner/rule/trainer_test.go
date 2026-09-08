package rule_test

import (
	"context"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/memory"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// planKindAndPOI is planWithMemory's sibling: the trainer rung is about which
// KIND is chosen as much as which place, and a helper that returns only the POI
// id cannot tell "went to the trainer" from "went to the grind area that
// happened to share an id".
func planKindAndPOI(t *testing.T, uuid string, mem memory.Reader, pois ...contract.PointOfInterest) (contract.IntentKind, string) {
	t.Helper()
	s := base()
	s.Bot.UUID = uuid
	s.POIs = pois
	p := rule.New(rule.Thresholds{})
	p.Memory = mem
	intents, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(intents) != 1 {
		t.Fatalf("intents = %d, want 1", len(intents))
	}
	if intents[0].Travel == nil {
		return intents[0].Kind, ""
	}
	return intents[0].Kind, intents[0].Travel.POIID
}

func refusedKind(kind string, n int) []memory.Observation {
	out := make([]memory.Observation, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, memory.Observation{
			Kind: kind, POIID: "tr1", Result: "failed", Reason: "action_refused",
		})
	}
	return out
}

// The loop this rung would otherwise be. "A trainer is near" stays true for as
// long as the bot stands near a trainer, so a rung with no other precondition
// walks a fully-trained bot back to the same NPC every tick and rung 8 is never
// reached. Repeated refusals of the KIND are what end it.
func TestRepeatedTrainerRefusalsFallThroughToGrinding(t *testing.T) {
	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: refusedKind(string(contract.IntentVisitTrainer), memory.KindRefusedThreshold),
	}}

	kind, id := planKindAndPOI(t, memUUID, mem,
		poi("tr1", "trainer", 5), poi("g1", "grind_area", 900))
	if kind != contract.IntentGrindArea || id != "g1" {
		t.Fatalf("got %s/%s, want grind_area/g1; the trainer rung never terminates", kind, id)
	}
}

// One refusal is not a pattern. A trainer with nothing to teach today has
// something to teach after the next level, and a bot that gave up on the first
// no would train once and never again.
func TestASingleTrainerRefusalDoesNotStopTraining(t *testing.T) {
	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: refusedKind(string(contract.IntentVisitTrainer), 1),
	}}

	kind, id := planKindAndPOI(t, memUUID, mem,
		poi("tr1", "trainer", 5), poi("g1", "grind_area", 900))
	if kind != contract.IntentVisitTrainer || id != "tr1" {
		t.Fatalf("got %s/%s, want visit_trainer/tr1", kind, id)
	}
}

// The distinction the outcome contract exists to draw. "The trainer would not
// teach me" says nothing whatever about where the trainer is, so it must not
// accumulate against the POI -- otherwise a bot that trained itself out of a
// trainer's list would go on to refuse every OTHER errand at the same place,
// and eventually treat a perfectly reachable town square as unreachable.
func TestTrainerRefusalsDoNotBlameThePOI(t *testing.T) {
	observations := refusedKind(string(contract.IntentVisitTrainer), memory.DiscouragedThreshold+3)
	h := memory.Build(observations)

	if got := h.DiscouragedCount("tr1"); got != 0 {
		t.Errorf("DiscouragedCount = %d, want 0: action_refused is about the kind, not the place", got)
	}
	if got := h.KindRefusedCount(string(contract.IntentVisitTrainer)); got != len(observations) {
		t.Errorf("KindRefusedCount = %d, want %d", got, len(observations))
	}

	// The consequence, which matters more than the counter: the same place is
	// still offered for a different errand. Only the trainer ERRAND was refused.
	mem := &fakeMemory{byBot: map[string][]memory.Observation{memUUID: observations}}
	kind, id := planKindAndPOI(t, memUUID, mem, poi("tr1", "grind_area", 5))
	if kind != contract.IntentGrindArea || id != "tr1" {
		t.Fatalf("got %s/%s, want grind_area/tr1; a refusal that was never about the place banned it", kind, id)
	}
}

// A refusal remembered against one bot must not train another bot's ladder.
func TestOneBotsTrainerRefusalsDoNotStopAnother(t *testing.T) {
	const other = "f47ac10b-58cc-4372-a567-0000000000aa"
	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: refusedKind(string(contract.IntentVisitTrainer), memory.KindRefusedThreshold+2),
	}}

	kind, id := planKindAndPOI(t, other, mem,
		poi("tr1", "trainer", 5), poi("g1", "grind_area", 900))
	if kind != contract.IntentVisitTrainer || id != "tr1" {
		t.Fatalf("got %s/%s, want visit_trainer/tr1", kind, id)
	}
}

// Refusals of a DIFFERENT kind must not close this rung. They are counted per
// kind for exactly this reason: "the vendor would not buy that" is not evidence
// about trainers.
func TestRefusalsOfAnotherKindDoNotStopTraining(t *testing.T) {
	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: refusedKind(string(contract.IntentVendorSell), memory.KindRefusedThreshold+2),
	}}

	kind, id := planKindAndPOI(t, memUUID, mem,
		poi("tr1", "trainer", 5), poi("g1", "grind_area", 900))
	if kind != contract.IntentVisitTrainer || id != "tr1" {
		t.Fatalf("got %s/%s, want visit_trainer/tr1", kind, id)
	}
}

// visit_trainer is POI-directed, so an intent for it must always name a POI and
// must always survive its own validator.
func TestVisitTrainerIntentIsWellFormed(t *testing.T) {
	s := base()
	s.POIs = []contract.PointOfInterest{poi("tr1", "trainer", 5)}
	in := planOne(t, s)

	if in.Kind != contract.IntentVisitTrainer {
		t.Fatalf("kind = %q, want visit_trainer", in.Kind)
	}
	if in.Travel == nil || in.Travel.POIID != "tr1" {
		t.Fatalf("travel = %+v, want poi tr1", in.Travel)
	}
	if err := in.Validate(); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if !in.Kind.IsKnown() {
		t.Fatal("the planner emitted a kind the contract does not list")
	}
}
