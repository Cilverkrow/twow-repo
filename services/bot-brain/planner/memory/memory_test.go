package memory

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// The distinction the whole package turns on. Getting it wrong does not fail
// loudly -- it teaches bots to avoid places that were never the problem, and the
// only symptom is bots that slowly stop going anywhere.
func TestOnlyDestinationFailuresCountAgainstAPOI(t *testing.T) {
	for _, tc := range []struct {
		name    string
		obs     Observation
		against bool
		why     string
	}{
		{"could not path there", Observation{Result: "failed", Reason: "unreachable"}, true,
			"the bot could not get there; that is the destination's fault"},
		{"server does not know the place", Observation{Result: "rejected", Reason: "unknown_poi"}, true,
			"the POI was not real"},
		{"the table it came from aged out", Observation{Result: "rejected", Reason: "stale_poi"}, true,
			"the destination no longer resolves"},
		{"failure with no reason given", Observation{Result: "failed", Reason: ""}, true,
			"a bare failure on a POI-directed intent is still about the POI"},

		{"something re-targeted the bot", Observation{Result: "superseded"}, false,
			"a group leader or admin moving the bot is not evidence about the place"},
		{"nobody watched it end", Observation{Result: "superseded", Reason: ""}, false,
			"an unobserved ending is not a failed destination"},
		{"the plan arrived too late", Observation{Result: "expired"}, false,
			"expiry is about latency, not geography"},
		{"nothing here can do that kind", Observation{Result: "rejected", Reason: "unsupported_kind"}, false,
			"about the kind, not the place"},
		{"the in-core action declined", Observation{Result: "failed", Reason: "action_refused"}, false,
			"about the action, not the place"},
		{"it worked", Observation{Result: "completed"}, false, "success is not evidence against anything"},
		{"it was taken", Observation{Result: "accepted"}, false, "not an ending at all"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.obs.Discouraging(); got != tc.against {
				t.Fatalf("Discouraging() = %v, want %v -- %s", got, tc.against, tc.why)
			}
		})
	}
}

func TestHistoryCountsPerPOI(t *testing.T) {
	h := Build([]Observation{
		{POIID: "p1", Result: "failed", Reason: "unreachable"},
		{POIID: "p1", Result: "failed", Reason: "unreachable"},
		{POIID: "p2", Result: "failed", Reason: "unreachable"},
		{POIID: "p3", Result: "completed"},
		{POIID: "p4", Result: "superseded"},
	})
	if got := h.DiscouragedCount("p1"); got != 2 {
		t.Fatalf("p1 = %d, want 2", got)
	}
	if got := h.DiscouragedCount("p2"); got != 1 {
		t.Fatalf("p2 = %d, want 1", got)
	}
	for _, id := range []string{"p3", "p4", "never-seen"} {
		if got := h.DiscouragedCount(id); got != 0 {
			t.Fatalf("%s = %d, want 0", id, got)
		}
	}
}

// A bot with no history must be usable without the caller checking for it, or
// every call site grows a branch and one of them eventually forgets.
func TestZeroHistoryIsUsable(t *testing.T) {
	var h History
	if got := h.DiscouragedCount("p1"); got != 0 {
		t.Fatalf("zero History returned %d", got)
	}
	if got := Build(nil).DiscouragedCount("p1"); got != 0 {
		t.Fatalf("Build(nil) returned %d", got)
	}
}

// An outcome with no POI says nothing about any destination and must not be
// counted against one -- least of all against the empty string, which every
// non-travel intent would share.
func TestObservationsWithoutAPOIAreIgnored(t *testing.T) {
	h := Build([]Observation{
		{POIID: "", Result: "failed", Reason: "unreachable"},
		{POIID: "", Result: "failed", Reason: "unreachable"},
	})
	if got := h.DiscouragedCount(""); got != 0 {
		t.Fatalf("empty POI counted %d times", got)
	}
}

// One failure is normal -- a mob in the way, a detour, a hiccup -- and the
// planner's existing one-tick avoidance already covers it. The threshold exists
// for the place that fails every time.
func TestThresholdIsAboveASingleFailure(t *testing.T) {
	if DiscouragedThreshold < 2 {
		t.Fatalf("DiscouragedThreshold = %d; a single failure must not ban a POI", DiscouragedThreshold)
	}
	if DefaultRecentLimit > DefaultRetention {
		t.Fatalf("reading %d per bot but keeping only %d", DefaultRecentLimit, DefaultRetention)
	}
}

// ---------------------------------------------------------------- recorder

type fakeRecorder struct {
	mu   sync.Mutex
	got  []Observation
	err  error
	hold chan struct{} // when non-nil, Record blocks until it is closed
}

func (f *fakeRecorder) Record(_ context.Context, _ string, o Observation) error {
	if f.hold != nil {
		<-f.hold
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.got = append(f.got, o)
	return f.err
}

func (f *fakeRecorder) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.got)
}

// The property that makes it safe to call from the request path.
func TestAsyncRecorderDoesNotBlockOnASlowStore(t *testing.T) {
	hold := make(chan struct{})
	store := &fakeRecorder{hold: hold}
	r := NewAsyncRecorder(store, AsyncOptions{QueueSize: 8, Workers: 1})

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 8; i++ {
			_ = r.Record(context.Background(), "uuid", Observation{Result: "failed"})
		}
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Record blocked while the store was slow -- this runs on the planning path")
	}

	close(hold)
	r.Stop()
	if store.count() == 0 {
		t.Fatal("nothing was written after the store recovered")
	}
}

// Bounded, not unbounded: a stalled database must cost history, never memory.
func TestAsyncRecorderDropsRatherThanGrows(t *testing.T) {
	hold := make(chan struct{})
	store := &fakeRecorder{hold: hold}
	var reported uint64
	var mu sync.Mutex
	r := NewAsyncRecorder(store, AsyncOptions{QueueSize: 2, Workers: 1,
		OnError: func(err error, dropped uint64) {
			if err == nil {
				mu.Lock()
				reported = dropped
				mu.Unlock()
			}
		}})

	for i := 0; i < 200; i++ {
		_ = r.Record(context.Background(), "uuid", Observation{Result: "failed"})
	}
	if r.Dropped() == 0 {
		t.Fatal("queue never dropped despite a blocked store and 200 writes")
	}
	mu.Lock()
	got := reported
	mu.Unlock()
	if got == 0 {
		t.Fatal("drops were not reported")
	}

	close(hold)
	r.Stop()
}

// A cancelled REQUEST must not cancel a write that is no longer part of it.
func TestRequestCancellationDoesNotCancelTheWrite(t *testing.T) {
	store := &fakeRecorder{}
	r := NewAsyncRecorder(store, AsyncOptions{QueueSize: 8, Workers: 1})

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := r.Record(ctx, "uuid", Observation{Result: "completed"}); err != nil {
		t.Fatalf("Record returned %v on a cancelled context", err)
	}
	r.Stop()
	if store.count() != 1 {
		t.Fatalf("wrote %d observations, want 1", store.count())
	}
}

func TestStoreErrorsAreReportedNotSwallowed(t *testing.T) {
	boom := errors.New("table is gone")
	store := &fakeRecorder{err: boom}
	var mu sync.Mutex
	var seen error
	r := NewAsyncRecorder(store, AsyncOptions{QueueSize: 4, Workers: 1,
		OnError: func(err error, _ uint64) {
			if err != nil {
				mu.Lock()
				seen = err
				mu.Unlock()
			}
		}})
	_ = r.Record(context.Background(), "uuid", Observation{Result: "failed"})
	r.Stop()

	mu.Lock()
	defer mu.Unlock()
	if !errors.Is(seen, boom) {
		t.Fatalf("OnError saw %v, want %v", seen, boom)
	}
}

// No store is a supported configuration, not a branch every caller must make.
func TestNilRecorderIsUsable(t *testing.T) {
	if r := NewAsyncRecorder(nil, AsyncOptions{QueueSize: 4, Workers: 1}); r != nil {
		t.Fatal("a nil store should yield a nil recorder")
	}
	var r *AsyncRecorder
	if err := r.Record(context.Background(), "uuid", Observation{}); err != nil {
		t.Fatalf("nil recorder returned %v", err)
	}
	if r.Dropped() != 0 {
		t.Fatal("nil recorder reported drops")
	}
	r.Stop()
}

func TestEmptyUUIDIsNotRecorded(t *testing.T) {
	store := &fakeRecorder{}
	r := NewAsyncRecorder(store, AsyncOptions{QueueSize: 4, Workers: 1})
	_ = r.Record(context.Background(), "", Observation{Result: "failed"})
	r.Stop()
	if store.count() != 0 {
		t.Fatal("an observation was stored against an empty uuid")
	}
}

// The mirror of TestOnlyDestinationFailuresCountAgainstAPOI. Exactly the
// outcomes that test excludes as "about the kind" are the ones this includes,
// and nothing that is about the destination may leak across: an unreachable
// place must not read as a kind the server cannot do, or one bad road would
// silently disable a whole rung of the ladder.
func TestOnlyKindRefusalsCountAgainstAKind(t *testing.T) {
	for _, tc := range []struct {
		name    string
		obs     Observation
		against bool
		why     string
	}{
		{"the in-core action declined", Observation{Result: "failed", Reason: "action_refused"}, true,
			"the bot got there and the thing asked for was not available"},
		{"this build cannot do that kind", Observation{Result: "rejected", Reason: "unsupported_kind"}, true,
			"the strongest form of the same statement; no destination fixes it"},
		{"refused before it started", Observation{Result: "rejected", Reason: "action_refused"}, true,
			"still about the action rather than the place"},

		{"could not path there", Observation{Result: "failed", Reason: "unreachable"}, false,
			"the road was bad, not the errand"},
		{"failure with no reason given", Observation{Result: "failed", Reason: ""}, false,
			"a bare failure is already counted against the POI; counting it twice would disable the rung too"},
		{"server does not know the place", Observation{Result: "rejected", Reason: "unknown_poi"}, false,
			"about the place"},
		{"the bot was busy", Observation{Result: "rejected", Reason: "in_combat"}, false,
			"about the bot's moment, not the kind"},
		{"identity was protected", Observation{Result: "rejected", Reason: "identity_protected"}, false,
			"a brain bug to surface, never a rung to quietly close"},
		{"the plan arrived too late", Observation{Result: "expired"}, false, "about latency"},
		{"it worked", Observation{Result: "completed"}, false, "success is not evidence against anything"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.obs.RefusedTheKind(); got != tc.against {
				t.Fatalf("RefusedTheKind() = %v, want %v -- %s", got, tc.against, tc.why)
			}
		})
	}
}

// Counted per kind, and an observation with no kind is counted against none.
func TestHistoryCountsRefusalsPerKind(t *testing.T) {
	h := Build([]Observation{
		{Kind: "visit_trainer", POIID: "tr1", Result: "failed", Reason: "action_refused"},
		{Kind: "visit_trainer", POIID: "tr2", Result: "failed", Reason: "action_refused"},
		{Kind: "vendor_sell", POIID: "v1", Result: "failed", Reason: "action_refused"},
		{Kind: "", POIID: "tr1", Result: "failed", Reason: "action_refused"},
		{Kind: "visit_trainer", POIID: "tr1", Result: "completed"},
	})

	if got := h.KindRefusedCount("visit_trainer"); got != 2 {
		t.Errorf("visit_trainer = %d, want 2", got)
	}
	if got := h.KindRefusedCount("vendor_sell"); got != 1 {
		t.Errorf("vendor_sell = %d, want 1", got)
	}
	if got := h.KindRefusedCount("repair"); got != 0 {
		t.Errorf("repair = %d, want 0", got)
	}
	if got := h.KindRefusedCount(""); got != 0 {
		t.Errorf("empty kind = %d, want 0: an observation with no kind is evidence about nothing", got)
	}
	// And none of it touched the POI counters.
	for _, id := range []string{"tr1", "tr2", "v1"} {
		if got := h.DiscouragedCount(id); got != 0 {
			t.Errorf("DiscouragedCount(%q) = %d, want 0", id, got)
		}
	}
}

// The zero History must answer both questions, so no caller has to branch on
// "this bot has no history".
func TestZeroHistoryAnswersKindRefusals(t *testing.T) {
	var h History
	if got := h.KindRefusedCount("visit_trainer"); got != 0 {
		t.Fatalf("KindRefusedCount on a zero History = %d, want 0", got)
	}
}
