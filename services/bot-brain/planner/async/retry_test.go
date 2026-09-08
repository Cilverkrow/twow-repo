package async

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/llm"
)

// failThenSucceed fails a fixed number of times, then answers.
type failThenSucceed struct {
	mu       sync.Mutex
	calls    int
	failWith error
	failures int
}

func (f *failThenSucceed) Name() string { return "flaky" }
func (f *failThenSucceed) Ready() bool  { return true }

func (f *failThenSucceed) Plan(_ context.Context, req planner.Request) ([]contract.Intent, error) {
	f.mu.Lock()
	f.calls++
	n := f.calls
	f.mu.Unlock()

	if n <= f.failures {
		return nil, f.failWith
	}
	out := make([]contract.Intent, 0, len(req.Snapshots))
	for i := range req.Snapshots {
		in := contract.Idle(req.Snapshots[i].Bot, "i", "flaky", "ok")
		in.ExpiresAtMS = req.ExpiryMS()
		out = append(out, in)
	}
	return out, nil
}

func (f *failThenSucceed) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// A provider that says "later" is waited out. This is only affordable because
// the lane runs between ticks -- the planner still refuses to retry inside a
// call that might be racing one.
func TestARateLimitIsWaitedOut(t *testing.T) {
	slow := &failThenSucceed{
		failures: 2,
		// A tiny Retry-After so the test does not actually sleep for seconds.
		failWith: &llm.StatusError{Code: http.StatusTooManyRequests, RetryAfter: 5 * time.Millisecond},
	}
	p := New(slow, Options{MaxAttempts: 3})
	defer p.Stop()

	s := snap(1)
	_, _ = p.Plan(context.Background(), req(1_000_000, s))

	waitFor(t, "the retries and the eventual success", func() bool { return slow.count() == 3 })
	waitFor(t, "an intent to become servable", func() bool {
		got, _ := p.Plan(context.Background(), req(1_000_000, s))
		return len(got) == 1
	})
	if r := p.Stats().Retried; r != 2 {
		t.Fatalf("Retried = %d, want 2", r)
	}
}

// A request that is simply wrong must not be repeated. A 400, a bad key or a
// missing model fails identically forever, and retrying turns one mistake into
// a stream of them -- billed, on a metered endpoint.
func TestANonRetryableFailureIsNotRepeated(t *testing.T) {
	for _, code := range []int{http.StatusBadRequest, http.StatusUnauthorized, http.StatusNotFound} {
		slow := &failThenSucceed{failures: 99, failWith: &llm.StatusError{Code: code}}
		p := New(slow, Options{MaxAttempts: 5})

		_, _ = p.Plan(context.Background(), req(1_000_000, snap(1)))
		waitFor(t, "the single attempt", func() bool { return slow.count() >= 1 })
		time.Sleep(50 * time.Millisecond) // any retry would have happened by now
		if n := slow.count(); n != 1 {
			t.Fatalf("status %d was attempted %d times, want 1", code, n)
		}
		if r := p.Stats().Retried; r != 0 {
			t.Fatalf("status %d counted %d retries", code, r)
		}
		p.Stop()
	}
}

// A transport failure is not retried inside the round either: the next round
// tries again anyway, and retrying here would only spend the same budget faster.
func TestATransportFailureIsNotRetriedInsideTheRound(t *testing.T) {
	slow := &failThenSucceed{failures: 99, failWith: errors.New("connection refused")}
	p := New(slow, Options{MaxAttempts: 5})
	defer p.Stop()

	_, _ = p.Plan(context.Background(), req(1_000_000, snap(1)))
	waitFor(t, "the attempt", func() bool { return slow.count() >= 1 })
	time.Sleep(50 * time.Millisecond)
	if n := slow.count(); n != 1 {
		t.Fatalf("a transport error was attempted %d times, want 1", n)
	}
}

// Attempts are bounded: a provider stuck on 429 must not be retried forever.
func TestRetriesAreBounded(t *testing.T) {
	slow := &failThenSucceed{
		failures: 99,
		failWith: &llm.StatusError{Code: http.StatusTooManyRequests, RetryAfter: time.Millisecond},
	}
	p := New(slow, Options{MaxAttempts: 3})
	defer p.Stop()

	_, _ = p.Plan(context.Background(), req(1_000_000, snap(1)))
	waitFor(t, "the attempts", func() bool { return slow.count() >= 3 })
	time.Sleep(50 * time.Millisecond)
	if n := slow.count(); n != 3 {
		t.Fatalf("made %d attempts, want the cap of 3", n)
	}
}

// The provider's own instruction wins. Choosing a shorter wait than it asked for
// is how a rate limit becomes a ban.
func TestTheProvidersRetryAfterIsHonoured(t *testing.T) {
	if got := backoff(1, 250*time.Millisecond); got != 250*time.Millisecond {
		t.Fatalf("backoff ignored Retry-After: %v", got)
	}
	// ...but not beyond the cap: a round that sat that long would answer from a
	// snapshot the world has moved past.
	if got := backoff(1, time.Hour); got != maxBackoff {
		t.Fatalf("backoff = %v, want the %v cap", got, maxBackoff)
	}
	// Without an instruction it doubles from a second, capped.
	if got := backoff(1, 0); got != time.Second {
		t.Fatalf("first backoff = %v, want 1s", got)
	}
	if got := backoff(2, 0); got != 2*time.Second {
		t.Fatalf("second backoff = %v, want 2s", got)
	}
	if got := backoff(20, 0); got != maxBackoff {
		t.Fatalf("late backoff = %v, want the cap", got)
	}
}

// MaxAttempts: 1 means "do not retry", and must be respected exactly.
func TestOneAttemptDisablesRetrying(t *testing.T) {
	slow := &failThenSucceed{
		failures: 99,
		failWith: &llm.StatusError{Code: http.StatusTooManyRequests, RetryAfter: time.Millisecond},
	}
	p := New(slow, Options{MaxAttempts: 1})
	defer p.Stop()

	_, _ = p.Plan(context.Background(), req(1_000_000, snap(1)))
	waitFor(t, "the attempt", func() bool { return slow.count() >= 1 })
	time.Sleep(50 * time.Millisecond)
	if n := slow.count(); n != 1 {
		t.Fatalf("made %d attempts with MaxAttempts=1", n)
	}
}
