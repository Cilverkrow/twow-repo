// Package planner defines what a bot brain actually is: something that turns
// snapshots into intents.
//
// Two implementations ship today. [github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule]
// is deterministic, has no network dependency and is the default. The llm
// subpackage talks to any OpenAI-compatible endpoint and is a skeleton.
//
// The rule that governs both: a bot never blocks on inference. [Fallback]
// enforces it structurally rather than by convention.
package planner

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

// Planner turns a batch of snapshots into intents.
//
// The batch shape is part of the interface, not a convenience: an LLM planner
// wants to see many bots per call so it can amortise a model round trip, and a
// per-snapshot interface would have made that impossible without a second
// batching layer.
//
// Contract for implementations:
//
//   - Respect ctx. A planner that ignores cancellation defeats [Fallback] and
//     therefore blocks bots on inference, which is the one thing this design
//     exists to prevent.
//   - Returning fewer intents than snapshots is legal and means "nothing to
//     suggest for those bots". It is not an error.
//   - Returning an intent for a bot that was not in the batch is a bug. The
//     transport drops such intents and counts them.
//   - Errors are for total failure. Per-bot failure is expressed by omitting
//     that bot's intent.
type Planner interface {
	// Name identifies the planner in metrics and in [contract.Intent.Source].
	Name() string
	// Plan returns intents for some or all of the snapshots.
	Plan(ctx context.Context, req Request) ([]contract.Intent, error)
	// Ready reports whether this planner can serve right now. It must not block
	// and must not do network I/O: readiness probes run often.
	Ready() bool
}

// Request is the planner-facing view of a batch. It carries the server clock
// explicitly, because intents' TTLs are expressed in the server's time base and
// no planner may reach for its own clock to compute them.
type Request struct {
	// Snapshots is the batch.
	Snapshots []contract.Snapshot
	// ServerNowMS is [contract.PlanRequest.SentAtMS]. Zero when the server did
	// not stamp the batch, in which case planners emit intents with no expiry.
	ServerNowMS int64
	// IntentTTLMS is how long intents produced from this batch stay valid, in
	// the server's clock. Set from configuration.
	IntentTTLMS int64
	// RequestID for logging.
	RequestID string
}

// ExpiryMS computes a server-clock expiry for an intent from this request, or
// zero when the server sent no clock. Every planner uses this rather than
// time.Now, so that a brain whose container clock is wrong still emits TTLs the
// server can enforce correctly.
func (r Request) ExpiryMS() int64 {
	if r.ServerNowMS == 0 || r.IntentTTLMS <= 0 {
		return 0
	}
	return r.ServerNowMS + r.IntentTTLMS
}

// NewIntentID returns a fresh opaque intent id. Random rather than sequential
// so that two brain replicas planning the same bot can never collide on an id,
// which would make outcome attribution silently wrong.
func NewIntentID() string {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand failing is not survivable in a sensible way, but an
		// intent with a degenerate id is still better than a panic that takes
		// a thousand bots' planning down with it. The nanosecond suffix keeps
		// ids unique enough to attribute outcomes.
		return "i-" + fmt.Sprintf("%016x", time.Now().UnixNano())
	}
	return "i-" + hex.EncodeToString(b[:])
}

// ErrPlannerUnavailable is returned by a planner that cannot serve at all.
var ErrPlannerUnavailable = errors.New("planner unavailable")

// Fallback wraps a primary planner with a deterministic secondary and a hard
// timeout.
//
// This is the structural guarantee behind "never let a bot block on inference".
// The primary gets Timeout to produce intents. Whatever it has not answered
// for -- because it timed out, errored, or simply returned fewer intents than
// there were snapshots -- is answered by the secondary, which is expected to be
// local, deterministic and fast.
//
// The primary is not cancelled merely because it is slow for *some* bots: the
// timeout applies to the whole call, and any bot it did answer for keeps that
// answer. Partial results from a slow primary are still better than none.
//
// Fallback is itself a [Planner], so it composes: a cloud LLM primary with a
// local LLM secondary with a rule tertiary is just two nested Fallbacks.
type Fallback struct {
	// Primary is tried first. Typically the LLM planner.
	Primary Planner
	// Secondary answers for everything the primary did not. It must be
	// deterministic and network-free, or the guarantee is not a guarantee.
	Secondary Planner
	// Timeout bounds the primary. Zero means the parent context is the only
	// bound, which is a configuration mistake for a network primary and is
	// allowed only so tests can express it.
	Timeout time.Duration

	// OnFallback, if set, is called once per batch with the number of bots the
	// secondary had to answer for and why. The HTTP layer uses it to drive
	// metrics without the planner package importing a metrics registry.
	OnFallback func(count int, reason string)

	mu sync.Mutex
}

func (f *Fallback) Name() string {
	return "fallback(" + f.Primary.Name() + "," + f.Secondary.Name() + ")"
}

// Ready reports true when the *secondary* is ready. A brain whose LLM is down
// is still a working brain -- that is the entire point -- so readiness must not
// depend on the primary. Reporting unready because an optional model is
// unreachable would take the service out of rotation for a condition it is
// designed to survive.
func (f *Fallback) Ready() bool { return f.Secondary.Ready() }

// Plan runs the primary under Timeout and fills every gap from the secondary.
func (f *Fallback) Plan(ctx context.Context, req Request) ([]contract.Intent, error) {
	answered := make(map[contract.BotID]contract.Intent, len(req.Snapshots))
	reason := ""

	if f.Primary != nil && f.Primary.Ready() {
		primaryCtx := ctx
		var cancel context.CancelFunc
		if f.Timeout > 0 {
			primaryCtx, cancel = context.WithTimeout(ctx, f.Timeout)
		}
		intents, err := f.Primary.Plan(primaryCtx, req)
		if cancel != nil {
			cancel()
		}
		switch {
		case err != nil && errors.Is(err, context.DeadlineExceeded):
			reason = "timeout"
		case err != nil && errors.Is(err, context.Canceled):
			reason = "canceled"
		case err != nil:
			reason = "error"
		}
		// Keep whatever the primary managed to produce, even alongside an
		// error: a partial answer is not a wrong answer.
		for _, in := range intents {
			if err := in.Validate(); err != nil {
				// A malformed intent from the primary is dropped here rather
				// than shipped. The secondary will cover the bot.
				continue
			}
			answered[in.Bot] = in
		}
	} else if f.Primary != nil {
		reason = "primary_not_ready"
	}

	missing := make([]contract.Snapshot, 0, len(req.Snapshots))
	for _, s := range req.Snapshots {
		if _, ok := answered[s.Bot]; !ok {
			missing = append(missing, s)
		}
	}

	fallbackCount := 0
	if len(missing) > 0 {
		if reason == "" {
			reason = "primary_incomplete"
		}
		subReq := req
		subReq.Snapshots = missing
		secondaryIntents, err := f.Secondary.Plan(ctx, subReq)
		if err != nil {
			// The secondary failing is the genuinely bad case: it is the thing
			// that is supposed to always work. Return what the primary gave and
			// let the transport report the rest as per-bot errors, so the
			// worldserver falls back to tier 0 for those bots.
			return collect(req.Snapshots, answered), fmt.Errorf("secondary planner failed: %w", err)
		}
		for i := range secondaryIntents {
			secondaryIntents[i].Source = "fallback"
			if err := secondaryIntents[i].Validate(); err != nil {
				continue
			}
			answered[secondaryIntents[i].Bot] = secondaryIntents[i]
			fallbackCount++
		}
	}

	if fallbackCount > 0 && f.OnFallback != nil {
		f.mu.Lock()
		cb := f.OnFallback
		f.mu.Unlock()
		cb(fallbackCount, reason)
	}
	return collect(req.Snapshots, answered), nil
}

// collect returns intents in snapshot order, which makes responses stable and
// therefore diffable in tests and in packet captures.
func collect(snaps []contract.Snapshot, answered map[contract.BotID]contract.Intent) []contract.Intent {
	out := make([]contract.Intent, 0, len(answered))
	for _, s := range snaps {
		if in, ok := answered[s.Bot]; ok {
			out = append(out, in)
		}
	}
	return out
}
