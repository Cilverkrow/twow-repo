package async

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
)

// slowPlanner stands in for a local model: it answers, eventually.
type slowPlanner struct {
	mu      sync.Mutex
	calls   int
	hold    chan struct{} // when non-nil, Plan blocks until closed
	err     error
	ready   bool
	ttlMS   int64
	lastReq planner.Request
}

func (s *slowPlanner) Name() string { return "slow" }
func (s *slowPlanner) Ready() bool  { return s.ready }

func (s *slowPlanner) Plan(ctx context.Context, req planner.Request) ([]contract.Intent, error) {
	if s.hold != nil {
		select {
		case <-s.hold:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	s.mu.Lock()
	s.calls++
	s.lastReq = req
	s.mu.Unlock()

	if s.err != nil {
		return nil, s.err
	}
	out := make([]contract.Intent, 0, len(req.Snapshots))
	for i := range req.Snapshots {
		in := contract.Idle(req.Snapshots[i].Bot, "intent-"+req.Snapshots[i].Bot.UUID, "slow", "because")
		if s.ttlMS != 0 {
			in.ExpiresAtMS = s.ttlMS
		} else {
			in.ExpiresAtMS = req.ExpiryMS()
		}
		out = append(out, in)
	}
	return out, nil
}

func (s *slowPlanner) callCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

func snap(guid uint64) contract.Snapshot {
	return contract.Snapshot{
		Bot:          contract.BotID{Realm: 1, GUID: guid, UUID: "u"},
		Char:         contract.Character{Name: "Bot", Level: 20, Class: 1, Race: 1, Faction: "alliance"},
		Vit:          contract.Vitals{HealthPct: 100},
		ObservedAtMS: 1_000_000,
	}
}

func req(now int64, snaps ...contract.Snapshot) planner.Request {
	return planner.Request{Snapshots: snaps, ServerNowMS: now, IntentTTLMS: 30_000}
}

// waitFor polls until cond or the deadline. The background lane is asynchronous
// by construction, so a test that asserts immediately is asserting on a race.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// The property the package exists for: a planner that takes eight seconds must
// not make the caller wait eight seconds.
func TestPlanDoesNotWaitForTheSlowPlanner(t *testing.T) {
	hold := make(chan struct{})
	slow := &slowPlanner{hold: hold, ready: true}
	p := New(slow, Options{})
	defer func() { close(hold); p.Stop() }()

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 5; i++ {
			_, _ = p.Plan(context.Background(), req(1_000_000, snap(uint64(i+1))))
		}
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Plan blocked on the slow planner -- the whole point is that it does not")
	}
}

// First tick answers for nobody; a later tick serves what the model decided.
func TestAnswersOnceTheSlowPlannerHasCaughtUp(t *testing.T) {
	slow := &slowPlanner{ready: true}
	p := New(slow, Options{})
	defer p.Stop()

	s := snap(1)
	intents, err := p.Plan(context.Background(), req(1_000_000, s))
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(intents) != 0 {
		t.Fatalf("first tick answered %d bots; nothing can be ready yet", len(intents))
	}

	waitFor(t, "the background round", func() bool { return slow.callCount() == 1 })

	waitFor(t, "an intent to become servable", func() bool {
		got, _ := p.Plan(context.Background(), req(1_000_000, s))
		return len(got) == 1
	})
}

// The staleness rule. An answer that took longer than its own validity must be
// dropped, not served late -- a plan made from a world that has moved on is
// worse than no plan.
func TestAnIntentThatAgedOutIsNotServed(t *testing.T) {
	slow := &slowPlanner{ready: true, ttlMS: 500_000} // expires long before "now" below
	p := New(slow, Options{})
	defer p.Stop()

	s := snap(1)
	_, _ = p.Plan(context.Background(), req(1_000_000, s))
	waitFor(t, "the background round", func() bool { return slow.callCount() == 1 })

	// Server clock is now well past the intent's expiry.
	got, err := p.Plan(context.Background(), req(9_000_000, s))
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("served %d expired intents", len(got))
	}
	waitFor(t, "the expiry to be counted", func() bool { return p.Stats().Expired == 1 })
}

// Freshness is judged in the SERVER's clock. This process may run on a different
// machine, and judging locally would serve stale intents whenever the two
// drifted apart.
func TestFreshnessUsesTheServerClockNotOurs(t *testing.T) {
	slow := &slowPlanner{ready: true, ttlMS: 2_000_000}
	p := New(slow, Options{})
	defer p.Stop()

	s := snap(1)
	_, _ = p.Plan(context.Background(), req(1_000_000, s))
	waitFor(t, "the background round", func() bool { return slow.callCount() == 1 })

	// A server clock BEFORE the expiry: the intent is fresh however long this
	// machine thinks it has been sitting there.
	waitFor(t, "the intent to be served as fresh", func() bool {
		got, _ := p.Plan(context.Background(), req(1_500_000, s))
		return len(got) == 1
	})
}

// A bot the model is still thinking about must not be re-queued every tick, or
// one slow bot crowds out the whole population.
func TestABotIsNotAskedAboutTwiceWhileInFlight(t *testing.T) {
	hold := make(chan struct{})
	slow := &slowPlanner{hold: hold, ready: true}
	p := New(slow, Options{QueueDepth: 8})
	defer func() { close(hold); p.Stop() }()

	s := snap(1)
	for i := 0; i < 10; i++ {
		_, _ = p.Plan(context.Background(), req(1_000_000, s))
	}
	if q := p.Stats().Queued; q != 1 {
		t.Fatalf("queued %d rounds for one in-flight bot, want 1", q)
	}
}

// Rounds are bounded, and the remainder is deliberately not carried over: those
// bots are asked about next tick with a fresher snapshot.
func TestRoundsAreBounded(t *testing.T) {
	hold := make(chan struct{})
	slow := &slowPlanner{hold: hold, ready: true}
	p := New(slow, Options{MaxBotsPerRound: 3})
	// This test releases the hold itself partway through, so the cleanup must
	// not close it a second time.
	defer p.Stop()

	snaps := make([]contract.Snapshot, 0, 10)
	for i := 0; i < 10; i++ {
		snaps = append(snaps, snap(uint64(i+1)))
	}
	_, _ = p.Plan(context.Background(), req(1_000_000, snaps...))

	close(hold)
	waitFor(t, "the round to run", func() bool { return slow.callCount() == 1 })
	slow.mu.Lock()
	got := len(slow.lastReq.Snapshots)
	slow.mu.Unlock()
	if got != 3 {
		t.Fatalf("round carried %d snapshots, want the cap of 3", got)
	}
}

// A full queue drops rather than grows: a backlog of rounds is a backlog of
// increasingly stale snapshots.
func TestAFullQueueDropsRounds(t *testing.T) {
	hold := make(chan struct{})
	slow := &slowPlanner{hold: hold, ready: true}
	p := New(slow, Options{QueueDepth: 1})
	defer func() { close(hold); p.Stop() }()

	for i := 0; i < 50; i++ {
		_, _ = p.Plan(context.Background(), req(1_000_000, snap(uint64(i+1))))
	}
	if p.Stats().Dropped == 0 {
		t.Fatal("queue never dropped despite a blocked planner and 50 rounds")
	}
}

// Readiness must not depend on having something to serve. If it did, Fallback
// would skip this lane and the ready set would never be drained.
func TestReadinessFollowsTheSlowPlannerNotTheReadySet(t *testing.T) {
	slow := &slowPlanner{ready: true}
	p := New(slow, Options{})
	defer p.Stop()

	if !p.Ready() {
		t.Fatal("not ready with an empty ready set; Fallback would skip this lane forever")
	}
	slow.ready = false
	if p.Ready() {
		t.Fatal("ready while the slow planner is not")
	}
}

// A failing model must not poison the lane: no intents, an error reported, and
// the bot released so it can be asked about again.
func TestAFailingSlowPlannerIsReportedAndReleasesTheBot(t *testing.T) {
	boom := errors.New("model is down")
	slow := &slowPlanner{ready: true, err: boom}

	var mu sync.Mutex
	var seen error
	p := New(slow, Options{OnError: func(err error) { mu.Lock(); seen = err; mu.Unlock() }})
	defer p.Stop()

	s := snap(1)
	_, _ = p.Plan(context.Background(), req(1_000_000, s))
	waitFor(t, "the failure to be reported", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return errors.Is(seen, boom)
	})
	// Asked about again on a later tick rather than stuck in flight forever.
	waitFor(t, "the bot to be re-queued", func() bool {
		_, _ = p.Plan(context.Background(), req(1_000_000, s))
		return slow.callCount() >= 2
	})
}

// No inference configured is a supported mode, not a branch at every call site.
func TestNilPlannerIsUsable(t *testing.T) {
	if p := New(nil, Options{}); p != nil {
		t.Fatal("a nil slow planner should yield a nil Planner")
	}
	var p *Planner
	if got, err := p.Plan(context.Background(), req(1, snap(1))); err != nil || got != nil {
		t.Fatalf("nil planner returned %v, %v", got, err)
	}
	if p.Ready() {
		t.Fatal("nil planner reports ready")
	}
	if p.Name() != "async(none)" {
		t.Fatalf("nil planner Name() = %q", p.Name())
	}
	p.Stop()
}

func TestStopIsIdempotent(t *testing.T) {
	p := New(&slowPlanner{ready: true}, Options{})
	p.Stop()
	p.Stop()
}

// An intent is served once. Serving the same stored answer on every tick until
// it expired would pin a bot to one decision for the life of that intent.
func TestAnIntentIsServedOnlyOnce(t *testing.T) {
	slow := &slowPlanner{ready: true}
	p := New(slow, Options{})
	defer p.Stop()

	s := snap(1)
	_, _ = p.Plan(context.Background(), req(1_000_000, s))
	waitFor(t, "an intent to become servable", func() bool {
		got, _ := p.Plan(context.Background(), req(1_000_000, s))
		return len(got) == 1
	})
	got, _ := p.Plan(context.Background(), req(1_000_000, s))
	if len(got) != 0 {
		t.Fatalf("the same intent was served twice")
	}
}
