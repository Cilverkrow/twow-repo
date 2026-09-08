package async

import (
	"context"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

// The failure this selection exists to prevent, stated as a test.
//
// The worldserver sends bots in a stable order. Taking the first N of the batch
// therefore asked about the SAME bots on every tick, forever, and the rest of
// the population was never planned for by the model at all -- while the metrics
// showed inference happening at exactly the configured rate. Invisible from
// outside, and permanent.
func TestEveryBotEventuallyGetsAskedAbout(t *testing.T) {
	slow := &slowPlanner{ready: true}
	p := New(slow, Options{MaxBotsPerRound: 4})
	defer p.Stop()

	const population = 40
	snaps := make([]contract.Snapshot, 0, population)
	for i := 0; i < population; i++ {
		snaps = append(snaps, snap(uint64(i+1)))
	}

	asked := map[uint64]bool{}
	// One tick at a time, each drained before the next. Ticks that overlap would
	// have rounds dropped by the bounded queue, and this test is about WHO gets
	// chosen, not about what happens when the worker falls behind -- which is
	// covered separately by TestAFullQueueDropsRounds.
	for tick := 0; tick < 40; tick++ {
		now := int64(1_000_000 + tick*15_000)
		before := slow.callCount()
		_, _ = p.Plan(context.Background(), req(now, snaps...))

		// Wait for this tick's round to be planned and its bots released, so the
		// next tick sees settled bookkeeping.
		waitFor(t, "the round to be planned", func() bool { return slow.callCount() > before })
		waitFor(t, "the round to settle", func() bool {
			p.mu.Lock()
			defer p.mu.Unlock()
			return len(p.inFlight) == 0
		})

		slow.mu.Lock()
		for i := range slow.lastReq.Snapshots {
			asked[slow.lastReq.Snapshots[i].Bot.GUID] = true
		}
		slow.mu.Unlock()

		if len(asked) == population {
			break
		}
	}

	if len(asked) < population {
		t.Fatalf("only %d of %d bots were ever asked about; attention is not spread",
			len(asked), population)
	}
}

// The tie-break must be deterministic. On the first tick nobody has been asked,
// so every bot ties on zero -- and resolving that by map iteration order would
// make the choice differ run to run for no reason anyone could explain.
func TestSelectionIsDeterministicWhenNobodyHasBeenAsked(t *testing.T) {
	choose := func() []uint64 {
		slow := &slowPlanner{ready: true, hold: make(chan struct{})}
		p := New(slow, Options{MaxBotsPerRound: 3})
		defer p.Stop()

		snaps := make([]contract.Snapshot, 0, 12)
		for i := 12; i >= 1; i-- { // deliberately not in id order
			snaps = append(snaps, snap(uint64(i)))
		}
		_, _ = p.Plan(context.Background(), req(1_000_000, snaps...))
		close(slow.hold)
		waitFor(t, "the round", func() bool { return slow.callCount() == 1 })

		slow.mu.Lock()
		defer slow.mu.Unlock()
		out := make([]uint64, 0, 3)
		for i := range slow.lastReq.Snapshots {
			out = append(out, slow.lastReq.Snapshots[i].Bot.GUID)
		}
		return out
	}

	first := choose()
	for i := 0; i < 3; i++ {
		got := choose()
		if len(got) != len(first) {
			t.Fatalf("round sizes differ: %v vs %v", got, first)
		}
		for j := range got {
			if got[j] != first[j] {
				t.Fatalf("selection differs between runs: %v then %v", first, got)
			}
		}
	}
}

// A bot asked about recently must yield to one that has not been asked at all.
func TestLeastRecentlyAskedWins(t *testing.T) {
	slow := &slowPlanner{ready: true}
	p := New(slow, Options{MaxBotsPerRound: 1})
	defer p.Stop()

	a, b := snap(1), snap(2)

	// Tick 1: only `a` is offered, so `a` is asked about.
	_, _ = p.Plan(context.Background(), req(1_000_000, a))
	waitFor(t, "the first round", func() bool { return slow.callCount() == 1 })

	// Tick 2: both offered, one slot. `b` has never been asked, so it wins.
	_, _ = p.Plan(context.Background(), req(1_015_000, a, b))
	waitFor(t, "the second round", func() bool { return slow.callCount() == 2 })

	slow.mu.Lock()
	chosen := slow.lastReq.Snapshots[0].Bot.GUID
	slow.mu.Unlock()
	if chosen != 2 {
		t.Fatalf("chose guid %d; the bot that had never been asked should win", chosen)
	}
}

// The bookkeeping must not grow without bound: bots log out and never return.
func TestDepartedBotsAreForgotten(t *testing.T) {
	slow := &slowPlanner{ready: true}
	p := New(slow, Options{MaxBotsPerRound: 1})
	defer p.Stop()

	// Fill past the pruning threshold with bots that are never seen again.
	p.mu.Lock()
	for i := 0; i < lastAskedSoftLimit+10; i++ {
		p.lastAsked[contract.BotID{Realm: 1, GUID: uint64(100000 + i)}] = 1_000_000
	}
	before := len(p.lastAsked)
	p.mu.Unlock()

	// A tick far enough in the future that those entries are past retention.
	_, _ = p.Plan(context.Background(), req(1_000_000+lastAskedRetentionMS+1, snap(1)))

	p.mu.Lock()
	after := len(p.lastAsked)
	p.mu.Unlock()
	if after >= before {
		t.Fatalf("lastAsked grew from %d to %d; departed bots are never forgotten", before, after)
	}
}
