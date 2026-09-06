package llm

import (
	"context"
	"errors"
	"math"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testBudget(t *testing.T, limits TokenLimits, clock func() time.Time) *TokenBudget {
	t.Helper()
	b, err := NewTokenBudget(limits, clock)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestTokenBudgetInvalidLimits(t *testing.T) {
	for _, l := range []TokenLimits{{}, {0, 1, 2, 3}, {-1, 1, 2, 3}, {1, 0, 2, 3}, {1, 1, 0, 3}, {1, 1, 2, 0}, {1, 1, 3, 2}, {2, 2, 3, 4}, {math.MaxInt64, 1, math.MaxInt64, math.MaxInt64}} {
		if _, err := NewTokenBudget(l, nil); err == nil {
			t.Errorf("accepted %+v", l)
		}
	}
	if _, err := (&TokenBudget{}).reserve(context.Background(), 1, 1); err == nil {
		t.Fatal("zero budget allowed")
	}
}

func TestTokenBudgetExactBounds(t *testing.T) {
	for _, tc := range []struct {
		in, out int64
		pass    bool
	}{{9, 4, true}, {10, 5, true}, {11, 5, false}, {10, 6, false}, {0, 1, false}, {1, 0, false}, {-1, 1, false}, {math.MaxInt64, math.MaxInt64, false}} {
		b := testBudget(t, TokenLimits{10, 5, 15, 30}, nil)
		_, err := b.reserve(context.Background(), tc.in, tc.out)
		if (err == nil) != tc.pass {
			t.Errorf("%+v: %v", tc, err)
		}
	}
	b := testBudget(t, TokenLimits{10, 5, 15, 30}, nil)
	if _, err := b.reserve(context.Background(), 9, 4); err != nil {
		t.Fatal(err)
	}
	if _, err := b.reserve(context.Background(), 1, 1); err != nil {
		t.Fatal("exact hourly limit", err)
	}
	if _, err := b.reserve(context.Background(), 1, 1); !errors.Is(err, ErrTokenBudget) {
		t.Fatal("exceeded hourly limit", err)
	}
	if b.usedHour != 15 || b.usedDay != 15 {
		t.Fatal("rejection mutated budget")
	}
}

func TestTokenBudgetWindowsAndClockRegression(t *testing.T) {
	var ns atomic.Int64
	epoch := time.Unix(0, 0)
	b := testBudget(t, TokenLimits{10, 5, 15, 30}, func() time.Time { return epoch.Add(time.Duration(ns.Load())) })
	reserve := func(want bool) {
		t.Helper()
		_, err := b.reserve(context.Background(), 10, 5)
		if (err == nil) != want {
			t.Fatalf("admission want %v: %v", want, err)
		}
	}
	reserve(true)
	ns.Store(int64(time.Hour - time.Nanosecond))
	reserve(false)
	ns.Store(int64(time.Hour))
	reserve(true)
	ns.Store(int64(2 * time.Hour))
	reserve(false) // day full even though hour renewed
	ns.Store(int64(24*time.Hour - time.Nanosecond))
	reserve(false)
	ns.Store(int64(24 * time.Hour))
	reserve(true)
	ns.Store(int64(time.Hour))
	reserve(false) // backwards cannot re-open old buckets
	ns.Store(int64(25 * time.Hour))
	reserve(true)
	ns.Store(int64(48 * time.Hour))
	reserve(true)
}

func TestTokenBudgetConcurrentReservations(t *testing.T) {
	b := testBudget(t, TokenLimits{8, 2, 100, 100}, nil)
	var wg sync.WaitGroup
	var accepted atomic.Int64
	start := make(chan struct{})
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			if _, err := b.reserve(context.Background(), 8, 2); err == nil {
				accepted.Add(1)
			}
		}()
	}
	close(start)
	wg.Wait()
	if accepted.Load() != 10 || b.usedHour != 100 || b.usedDay != 100 {
		t.Fatal("non-atomic budget", accepted.Load(), b.usedHour, b.usedDay)
	}
}

func TestTokenBudgetUsageNeverRefunds(t *testing.T) {
	for _, raw := range []string{`{}`, `{"usage":null}`, `{"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`} {
		b := testBudget(t, TokenLimits{10, 5, 15, 15}, nil)
		r, _ := b.reserve(context.Background(), 10, 5)
		if err := r.observeUsage([]byte(raw)); err != nil {
			t.Fatal(err)
		}
		// Repeated evidence is idempotent too: no refund or second charge.
		if err := r.observeUsage([]byte(raw)); err != nil {
			t.Fatal(err)
		}
		if _, err := b.reserve(context.Background(), 1, 1); err == nil || b.usedDay != 15 {
			t.Fatal("refund bypass")
		}
	}
}

func TestTokenBudgetInvalidUsageLatches(t *testing.T) {
	for _, usage := range []string{`{}`, `[]`, `{"prompt_tokens":11,"completion_tokens":1,"total_tokens":12}`, `{"prompt_tokens":1,"completion_tokens":6,"total_tokens":7}`, `{"prompt_tokens":1,"completion_tokens":1,"total_tokens":3}`, `{"prompt_tokens":-1,"completion_tokens":1,"total_tokens":0}`, `{"prompt_tokens":1.5,"completion_tokens":1,"total_tokens":2}`, `{"prompt_tokens":null,"completion_tokens":1,"total_tokens":1}`, `{"prompt_tokens":1,"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}`, `{"prompt_tokens":9223372036854775807,"completion_tokens":1,"total_tokens":0}`} {
		b := testBudget(t, TokenLimits{10, 5, 30, 60}, nil)
		r, _ := b.reserve(context.Background(), 10, 5)
		if err := r.observeUsage([]byte(`{"usage":` + usage + `}`)); !errors.Is(err, ErrTokenUsage) {
			t.Fatal("accepted usage", usage, err)
		}
		if _, err := b.reserve(context.Background(), 1, 1); err == nil {
			t.Fatal("latch reopened")
		}
	}
}

// Every other usage fixture in this file is the bare three-key triple, which is
// not what any current provider sends. OpenAI, Azure OpenAI, OpenRouter and
// vLLM >= 0.6 all nest prompt_tokens_details / completion_tokens_details inside
// usage. Rejecting an unrecognised key latched the budget process-wide on the
// first ordinary 200 OK, with no reset, so this fixture is the difference
// between a red test and a silent production outage.
//
// Not latching is asserted the way the sibling tests assert the opposite: a
// further reserve must still succeed.
func TestTokenBudgetAcceptsProviderUsageDetails(t *testing.T) {
	for _, usage := range []string{
		`{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0}}`,
		`{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"some_future_field":"whatever"}`,
		`{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"nullable_extra":null}`,
		`{"prompt_tokens_details":{"cached_tokens":0},"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}`,
	} {
		b := testBudget(t, TokenLimits{10, 5, 30, 60}, nil)
		r, err := b.reserve(context.Background(), 1, 1)
		if err != nil {
			t.Fatalf("reserve: %v", err)
		}
		if err := r.observeUsage([]byte(`{"usage":` + usage + `}`)); err != nil {
			t.Errorf("rejected a realistic provider usage object: %v -- %s", err, usage)
			continue
		}
		if _, err := b.reserve(context.Background(), 1, 1); err != nil {
			t.Errorf("budget latched on an unrecognised key: %v -- %s", err, usage)
		}
	}
}

func TestTokenBudgetLateUsageCannotRefundNewWindow(t *testing.T) {
	now := time.Unix(0, 0)
	b := testBudget(t, TokenLimits{10, 5, 15, 15}, func() time.Time { return now })
	old, _ := b.reserve(context.Background(), 10, 5)
	now = now.Add(24 * time.Hour)
	b.reserve(context.Background(), 10, 5)
	if err := old.observeUsage([]byte(`{"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)); err != nil {
		t.Fatal(err)
	}
	if b.usedHour != 15 || b.usedDay != 15 {
		t.Fatal("old completion altered new window")
	}
	if err := old.observeUsage([]byte(`{"usage":{"prompt_tokens":11,"completion_tokens":1,"total_tokens":12}}`)); err == nil {
		t.Fatal("late overage accepted")
	}
	now = now.Add(24 * time.Hour)
	if _, err := b.reserve(context.Background(), 1, 1); err == nil {
		t.Fatal("window change reopened latch")
	}
}

func TestTokenBudgetCancelledAndStopped(t *testing.T) {
	b := testBudget(t, TokenLimits{10, 5, 15, 15}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := b.reserve(ctx, 1, 1); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if b.usedDay != 0 {
		t.Fatal("cancelled before admission was charged")
	}
	b.Stop()
	if _, err := b.reserve(context.Background(), 1, 1); err == nil {
		t.Fatal("stopped admitted")
	}
}
