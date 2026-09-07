package rule_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/memory"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

type fakeMemory struct {
	byBot map[string][]memory.Observation
	err   error
	calls int
}

func (f *fakeMemory) Recent(_ context.Context, uuids []string, _ int) (map[string][]memory.Observation, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	out := make(map[string][]memory.Observation, len(uuids))
	for _, u := range uuids {
		if obs, ok := f.byBot[u]; ok {
			out[u] = obs
		}
	}
	return out, nil
}

func failedAt(poi string, n int) []memory.Observation {
	out := make([]memory.Observation, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, memory.Observation{POIID: poi, Result: "failed", Reason: "unreachable"})
	}
	return out
}

func planWithMemory(t *testing.T, uuid string, mem memory.Reader, pois ...contract.PointOfInterest) string {
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
		return "" // idle: nowhere left to go
	}
	return intents[0].Travel.POIID
}

const memUUID = "f47ac10b-58cc-4372-a567-0000000000ff"

// The behaviour this whole phase exists for. The nearest POI is one the bot has
// repeatedly failed to reach, so it should stop being offered -- something the
// single-tick avoidance could never do, because it only remembers the LAST
// outcome and any other intent in between clears it.
func TestRepeatedlyFailedPOIIsNoLongerChosen(t *testing.T) {
	near := poi("cursed", "grind_area", 100)
	far := poi("fine", "grind_area", 900)

	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: failedAt("cursed", memory.DiscouragedThreshold),
	}}

	if got := planWithMemory(t, memUUID, mem, near, far); got != "fine" {
		t.Fatalf("chose %q; a POI this bot repeatedly cannot reach was chosen again", got)
	}
	// Without the history, the near one is what it picks -- otherwise this test
	// would pass for the wrong reason.
	if got := planWithMemory(t, memUUID, nil, near, far); got != "cursed" {
		t.Fatalf("control: chose %q, want the nearest %q", got, "cursed")
	}
}

// One failure is not a pattern. The existing one-tick avoidance handles that
// case, and banning a POI on a single bad trip would make bots abandon places
// over a mob that happened to be standing there.
func TestASingleFailureDoesNotBanAPOI(t *testing.T) {
	near := poi("unlucky", "grind_area", 100)
	far := poi("fine", "grind_area", 900)

	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: failedAt("unlucky", 1),
	}}
	if got := planWithMemory(t, memUUID, mem, near, far); got != "unlucky" {
		t.Fatalf("chose %q; one failure should not be enough to give up on a place", got)
	}
}

// History belongs to a bot, not to the world. One bot's bad experience must not
// steer another's choices.
func TestOneBotsHistoryDoesNotAffectAnother(t *testing.T) {
	near := poi("cursed", "grind_area", 100)
	far := poi("fine", "grind_area", 900)

	const other = "f47ac10b-58cc-4372-a567-0000000000ee"
	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: failedAt("cursed", 5),
	}}
	if got := planWithMemory(t, other, mem, near, far); got != "cursed" {
		t.Fatalf("bot with no history chose %q; it inherited another bot's memory", got)
	}
}

// Outcomes that are not about the destination must not accumulate against it.
// A bot re-targeted five times by a group leader has learned nothing about the
// place it was walking to.
func TestNonDestinationOutcomesDoNotBanAPOI(t *testing.T) {
	near := poi("innocent", "grind_area", 100)
	far := poi("fine", "grind_area", 900)

	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: {
			{POIID: "innocent", Result: "superseded"},
			{POIID: "innocent", Result: "superseded"},
			{POIID: "innocent", Result: "expired"},
			{POIID: "innocent", Result: "completed"},
			{POIID: "innocent", Result: "failed", Reason: "action_refused"},
		},
	}}
	if got := planWithMemory(t, memUUID, mem, near, far); got != "innocent" {
		t.Fatalf("chose %q; outcomes that say nothing about the destination banned it anyway", got)
	}
}

// A memory lookup that fails must cost history, never a plan. This is the same
// trade the trait store makes, and the opposite of admission's -- because here
// there is a safe answer, and it is the behaviour the planner had before it
// could remember anything.
func TestMemoryFailureStillPlans(t *testing.T) {
	near := poi("cursed", "grind_area", 100)
	mem := &fakeMemory{err: errors.New("database is on fire")}

	var reported error
	s := base()
	s.Bot.UUID = memUUID
	s.POIs = []contract.PointOfInterest{near}
	p := rule.New(rule.Thresholds{})
	p.Memory = mem
	p.OnMemoryError = func(err error) { reported = err }

	intents, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}})
	if err != nil {
		t.Fatalf("Plan returned %v; a memory failure must not fail planning", err)
	}
	if len(intents) != 1 || intents[0].Travel == nil || intents[0].Travel.POIID != "cursed" {
		t.Fatalf("planner did not fall back to memoryless behaviour: %+v", intents)
	}
	if reported == nil {
		t.Fatal("the failure was swallowed instead of reported")
	}
}

// One lookup per batch, not one per bot: a batch may carry 2048 bots and a
// per-bot query inside a planning deadline would spend it before the plan did.
func TestMemoryIsReadOncePerBatch(t *testing.T) {
	mem := &fakeMemory{byBot: map[string][]memory.Observation{}}
	p := rule.New(rule.Thresholds{})
	p.Memory = mem

	snaps := make([]contract.Snapshot, 0, 32)
	for i := 0; i < 32; i++ {
		s := base()
		s.Bot.UUID = uuidN(i)
		s.Bot.GUID = uint64(i + 1)
		s.POIs = []contract.PointOfInterest{poi("p", "grind_area", 100)}
		snaps = append(snaps, s)
	}
	if _, err := p.Plan(context.Background(), planner.Request{Snapshots: snaps}); err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if mem.calls != 1 {
		t.Fatalf("memory was read %d times for one batch of 32 bots", mem.calls)
	}
}

// A bot that has failed everywhere still gets an answer -- idle, not a crash and
// not an intent naming a POI it was supposed to avoid.
func TestEveryPOIDiscouragedStillYieldsAnIntent(t *testing.T) {
	only := poi("cursed", "grind_area", 100)
	mem := &fakeMemory{byBot: map[string][]memory.Observation{
		memUUID: failedAt("cursed", 5),
	}}
	if got := planWithMemory(t, memUUID, mem, only); got != "" {
		t.Fatalf("chose %q, want no travel at all", got)
	}
}
