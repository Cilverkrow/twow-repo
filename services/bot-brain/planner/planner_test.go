package planner_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// stub is a scriptable planner. Nothing in these tests touches the network:
// "slow" is a sleep, not a real endpoint.
type stub struct {
	name string
	// delay is how long Plan blocks before answering. It always honours ctx.
	delay time.Duration
	// answerFor limits which snapshot indices get an intent, so partial answers
	// can be expressed.
	answerFor func(i int) bool
	err       error
	ready     bool
	// malformed makes the produced intents invalid, to prove they are dropped.
	malformed bool
	// foreign makes the planner answer for a bot that was not in the batch.
	foreign bool
	calls   int
}

func (s *stub) Name() string { return s.name }
func (s *stub) Ready() bool  { return s.ready }

func (s *stub) Plan(ctx context.Context, req planner.Request) ([]contract.Intent, error) {
	s.calls++
	if s.delay > 0 {
		select {
		case <-time.After(s.delay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if s.err != nil {
		return nil, s.err
	}
	out := make([]contract.Intent, 0, len(req.Snapshots))
	for i, snap := range req.Snapshots {
		if s.answerFor != nil && !s.answerFor(i) {
			continue
		}
		in := contract.Idle(snap.Bot, planner.NewIntentID(), s.name, "stub")
		if s.malformed {
			in.Kind = contract.IntentKind("not_a_kind")
		}
		if s.foreign {
			in.Bot = contract.BotID{Realm: 99, GUID: 999999}
		}
		out = append(out, in)
	}
	return out, nil
}

func snaps(n int) []contract.Snapshot {
	out := make([]contract.Snapshot, n)
	for i := range out {
		out[i] = contract.Snapshot{
			Bot:  contract.BotID{Realm: 1, GUID: uint64(i + 1)},
			Char: contract.Character{Level: 20, Faction: "alliance", FreeBagSlots: 10},
			Vit:  contract.Vitals{HealthPct: 100},
			Pos:  contract.Position{MapID: 0},
		}
	}
	return out
}

func sourceCounts(intents []contract.Intent) map[string]int {
	m := map[string]int{}
	for _, in := range intents {
		m[in.Source]++
	}
	return m
}

// The core guarantee: a slow primary never costs a bot its plan.
func TestFallbackCoversEveryBot(t *testing.T) {
	tests := []struct {
		name          string
		primary       *stub
		timeout       time.Duration
		batch         int
		wantFallback  int
		wantPrimary   int
		wantReason    string
		wantTotal     int
		primaryCalled bool
	}{
		{
			name:          "primary times out: every bot is covered by rules",
			primary:       &stub{name: "slow", ready: true, delay: 200 * time.Millisecond},
			timeout:       10 * time.Millisecond,
			batch:         5,
			wantFallback:  5,
			wantTotal:     5,
			wantReason:    "timeout",
			primaryCalled: true,
		},
		{
			name:          "primary errors",
			primary:       &stub{name: "broken", ready: true, err: errors.New("boom")},
			timeout:       time.Second,
			batch:         3,
			wantFallback:  3,
			wantTotal:     3,
			wantReason:    "error",
			primaryCalled: true,
		},
		{
			name:          "primary answers everything",
			primary:       &stub{name: "fast", ready: true},
			timeout:       time.Second,
			batch:         4,
			wantPrimary:   4,
			wantTotal:     4,
			primaryCalled: true,
		},
		{
			name: "primary answers half; the rest fall back",
			primary: &stub{name: "partial", ready: true,
				answerFor: func(i int) bool { return i%2 == 0 }},
			timeout:       time.Second,
			batch:         6,
			wantPrimary:   3,
			wantFallback:  3,
			wantTotal:     6,
			wantReason:    "primary_incomplete",
			primaryCalled: true,
		},
		{
			name:         "primary not ready is skipped entirely",
			primary:      &stub{name: "down", ready: false, delay: time.Hour},
			timeout:      time.Second,
			batch:        2,
			wantFallback: 2,
			wantTotal:    2,
			wantReason:   "primary_not_ready",
		},
		{
			name:          "primary returns malformed intents; they are dropped and covered",
			primary:       &stub{name: "garbage", ready: true, malformed: true},
			timeout:       time.Second,
			batch:         3,
			wantFallback:  3,
			wantTotal:     3,
			wantReason:    "primary_incomplete",
			primaryCalled: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var gotCount int
			var gotReason string
			fb := &planner.Fallback{
				Primary:   tc.primary,
				Secondary: rule.New(rule.Thresholds{}),
				Timeout:   tc.timeout,
				OnFallback: func(count int, reason string) {
					gotCount, gotReason = count, reason
				},
			}
			batch := snaps(tc.batch)
			intents, err := fb.Plan(context.Background(), planner.Request{
				Snapshots:   batch,
				ServerNowMS: 1_700_000_000_000,
				IntentTTLMS: 30_000,
			})
			if err != nil {
				t.Fatalf("Plan returned an error: %v", err)
			}
			if len(intents) != tc.wantTotal {
				t.Fatalf("got %d intents, want %d (every plannable bot must get one)", len(intents), tc.wantTotal)
			}
			counts := sourceCounts(intents)
			if counts["fallback"] != tc.wantFallback {
				t.Errorf("fallback intents = %d, want %d (all: %v)", counts["fallback"], tc.wantFallback, counts)
			}
			if tc.wantPrimary > 0 && counts[tc.primary.name] != tc.wantPrimary {
				t.Errorf("primary intents = %d, want %d (all: %v)", counts[tc.primary.name], tc.wantPrimary, counts)
			}
			if tc.wantFallback > 0 {
				if gotCount != tc.wantFallback {
					t.Errorf("OnFallback count = %d, want %d", gotCount, tc.wantFallback)
				}
				if tc.wantReason != "" && gotReason != tc.wantReason {
					t.Errorf("OnFallback reason = %q, want %q", gotReason, tc.wantReason)
				}
			}
			if tc.primaryCalled && tc.primary.calls == 0 {
				t.Error("primary was never called")
			}
			if !tc.primaryCalled && tc.primary.calls != 0 {
				t.Errorf("primary was called %d times but should have been skipped", tc.primary.calls)
			}
			// Every intent must be addressed to a bot that was in the batch.
			asked := map[contract.BotID]bool{}
			for _, s := range batch {
				asked[s.Bot] = true
			}
			for _, in := range intents {
				if !asked[in.Bot] {
					t.Fatalf("intent addressed to bot %s which was not in the batch", in.Bot)
				}
			}
		})
	}
}

// A slow primary must not be able to hold a batch past its timeout. This is the
// "never block on inference" guarantee measured rather than asserted.
func TestFallbackReturnsWithinTimeout(t *testing.T) {
	fb := &planner.Fallback{
		Primary:   &stub{name: "molasses", ready: true, delay: 5 * time.Second},
		Secondary: rule.New(rule.Thresholds{}),
		Timeout:   50 * time.Millisecond,
	}
	start := time.Now()
	intents, err := fb.Plan(context.Background(), planner.Request{Snapshots: snaps(10)})
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Plan returned an error: %v", err)
	}
	if len(intents) != 10 {
		t.Fatalf("got %d intents, want 10", len(intents))
	}
	// Generous ceiling: the point is that it did not wait 5 seconds.
	if elapsed > 2*time.Second {
		t.Fatalf("batch took %s; the primary's timeout should have bounded it near 50ms", elapsed)
	}
}

// If the secondary itself fails, that is the genuinely bad case. The primary's
// partial results still ship and the error is surfaced, so the transport can
// report the uncovered bots and the worldserver keeps them on tier-0 AI.
func TestFallbackSurfacesSecondaryFailure(t *testing.T) {
	fb := &planner.Fallback{
		Primary: &stub{name: "partial", ready: true,
			answerFor: func(i int) bool { return i == 0 }},
		Secondary: &stub{name: "broken-secondary", ready: true, err: errors.New("no")},
		Timeout:   time.Second,
	}
	intents, err := fb.Plan(context.Background(), planner.Request{Snapshots: snaps(3)})
	if err == nil {
		t.Fatal("expected an error when the secondary fails")
	}
	if len(intents) != 1 {
		t.Fatalf("got %d intents, want 1 (the primary's partial answer must survive)", len(intents))
	}
}

// Readiness must not depend on the primary: a brain with a dead model is still
// a working brain, and reporting unready would remove it from rotation for a
// condition it is designed to survive.
func TestFallbackReadinessIgnoresPrimary(t *testing.T) {
	fb := &planner.Fallback{
		Primary:   &stub{name: "down", ready: false},
		Secondary: rule.New(rule.Thresholds{}),
	}
	if !fb.Ready() {
		t.Fatal("fallback reported unready while its deterministic secondary was fine")
	}
}

func TestExpiryComesFromTheServerClock(t *testing.T) {
	tests := []struct {
		name        string
		serverNowMS int64
		ttlMS       int64
		want        int64
	}{
		{name: "normal", serverNowMS: 1000, ttlMS: 500, want: 1500},
		{name: "no server clock means no expiry", serverNowMS: 0, ttlMS: 500, want: 0},
		{name: "no ttl means no expiry", serverNowMS: 1000, ttlMS: 0, want: 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := planner.Request{ServerNowMS: tc.serverNowMS, IntentTTLMS: tc.ttlMS}
			if got := req.ExpiryMS(); got != tc.want {
				t.Fatalf("ExpiryMS = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestNewIntentIDIsUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		id := planner.NewIntentID()
		if seen[id] {
			t.Fatalf("duplicate intent id %q; outcome attribution would be silently wrong", id)
		}
		seen[id] = true
	}
}

// A batch of a thousand bots is the load this design exists for; the fallback
// wrapper must not be quadratic or otherwise fall over at that size.
func TestFallbackHandlesThousandBotBatch(t *testing.T) {
	fb := &planner.Fallback{
		Primary:   &stub{name: "down", ready: false},
		Secondary: rule.New(rule.Thresholds{}),
		Timeout:   time.Second,
	}
	intents, err := fb.Plan(context.Background(), planner.Request{Snapshots: snaps(1000)})
	if err != nil {
		t.Fatalf("Plan returned an error: %v", err)
	}
	if len(intents) != 1000 {
		t.Fatalf("got %d intents, want 1000", len(intents))
	}
}
