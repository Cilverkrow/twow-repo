// Package async lets a planner that is far too slow for a tick still decide
// what bots do.
//
// The problem it exists for is measured, not hypothetical. LLM-011 timed a local
// 7B on CPU at about eight seconds per answer. BOT_BRAIN_LLM_TIMEOUT defaults to
// 1500ms and must stay below the planning deadline, because the deterministic
// planner needs budget to answer in. So a local endpoint loses the race on every
// single batch, every batch falls back to rules, and the model contributes
// nothing at all. That outcome is correct, visible, and useless.
//
// The fix is not a faster model or a longer deadline. It is to stop making the
// model race the tick:
//
//	tick N      serve whatever the model has already decided; ask about some bots
//	...         the model thinks, for as long as it needs
//	tick N+k    its answer is ready, and is served then
//
// Nothing here weakens staleness. An intent still carries the ExpiresAtMS the
// slow planner stamped from the request it was planned against, so an answer
// that took too long expires on its own; and the worldserver independently
// refuses a POI whose table has aged out. This package adds a delay, never a
// licence to act on old information.
//
// It is deliberately NOT a cache in front of a fast planner. The rule planner is
// already fast and always answers; this exists so a slow one can contribute at
// all, and every bot it has nothing for is left to fall through to rules by
// [planner.Fallback], which already merges a primary that answers for a subset.
package async

import (
	"context"
	"sync"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
)

// Options configures a [Planner].
type Options struct {
	// MaxBotsPerRound is how many bots one background call asks about. Zero
	// means the slow planner's own batching decides.
	MaxBotsPerRound int
	// Timeout bounds one background call. This is the number that may be
	// generous: it is not inside anyone's tick. Zero means 30s.
	Timeout time.Duration
	// QueueDepth bounds rounds waiting to be planned. Zero means 4.
	QueueDepth int
	// OnError reports a failed background call. Nil means silence.
	OnError func(error)
	// Now is injectable for tests. Nil means time.Now.
	Now func() time.Time
}

// Planner serves what a slow planner has already decided.
type Planner struct {
	slow planner.Planner
	opts Options

	queue chan []contract.Snapshot
	wg    sync.WaitGroup
	stop  sync.Once

	mu sync.Mutex
	// ready holds the newest intent per bot, waiting to be served. One per bot,
	// not a queue: an older opinion about the same bot is always worse than a
	// newer one, and holding both would mean serving a stale plan first and the
	// fresh one a tick later.
	ready map[contract.BotID]contract.Intent
	// inFlight marks bots already queued, so a bot is not asked about twice
	// while the model is still thinking about it. Without this, a bot that the
	// model is slow on gets re-queued on every tick and crowds out every other
	// bot in the population.
	inFlight map[contract.BotID]bool

	stats Stats
}

// Stats is what this lane is doing, for /metrics and for answering "is the model
// contributing anything at all".
type Stats struct {
	// Served is intents handed to a caller from the ready set.
	Served uint64
	// Expired is intents the slow planner produced that aged out before anyone
	// asked for them. Persistently high means the model is slower than the
	// intent TTL and this lane cannot help at that latency.
	Expired uint64
	// Queued is rounds handed to the background worker.
	Queued uint64
	// Dropped is rounds refused because the queue was full.
	Dropped uint64
}

// New wraps a slow planner. A nil slow planner yields nil, which callers may
// use directly: that is the configuration with no inference at all.
func New(slow planner.Planner, opts Options) *Planner {
	if slow == nil {
		return nil
	}
	if opts.Timeout <= 0 {
		opts.Timeout = 30 * time.Second
	}
	if opts.QueueDepth <= 0 {
		opts.QueueDepth = 4
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}

	p := &Planner{
		slow:     slow,
		opts:     opts,
		queue:    make(chan []contract.Snapshot, opts.QueueDepth),
		ready:    make(map[contract.BotID]contract.Intent),
		inFlight: make(map[contract.BotID]bool),
	}
	p.wg.Add(1)
	go p.run()
	return p
}

func (p *Planner) Name() string {
	if p == nil {
		return "async(none)"
	}
	return "async(" + p.slow.Name() + ")"
}

// Ready is true whenever the slow planner is.
//
// Note what this does NOT depend on: whether anything is in the ready set. A
// planner that answers for no bots is a normal state here -- the model has not
// finished thinking yet -- and [planner.Fallback] sends every unanswered bot to
// the rule planner. Reporting not-ready would make Fallback skip this lane
// entirely and the ready set would never be drained.
func (p *Planner) Ready() bool {
	if p == nil {
		return false
	}
	return p.slow.Ready()
}

// Plan serves already-decided intents and queues a round of fresh work.
//
// It does not call the slow planner, and so cannot block on it. Bots with
// nothing ready are simply absent from the result.
func (p *Planner) Plan(ctx context.Context, req planner.Request) ([]contract.Intent, error) {
	if p == nil || len(req.Snapshots) == 0 {
		return nil, nil
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// The SERVER's clock, never ours. Intent expiry is defined in the
	// worldserver's clock (contract.Intent.ExpiresAtMS), and this process may
	// be on a different machine with a different idea of the time. Judging
	// freshness locally would silently serve stale intents whenever the two
	// drifted apart.
	now := req.ServerNowMS

	out := make([]contract.Intent, 0, len(req.Snapshots))
	askAbout := make([]contract.Snapshot, 0, len(req.Snapshots))

	p.mu.Lock()
	for i := range req.Snapshots {
		bot := req.Snapshots[i].Bot
		in, ok := p.ready[bot]
		if !ok {
			if !p.inFlight[bot] {
				askAbout = append(askAbout, req.Snapshots[i])
			}
			continue
		}
		delete(p.ready, bot)

		if now > 0 && in.ExpiresAtMS > 0 && in.ExpiresAtMS < now {
			// Thought about for too long. Dropped rather than served late:
			// the whole reason intents expire is that a plan made from a
			// snapshot the world has moved past is worse than no plan.
			p.stats.Expired++
			askAbout = append(askAbout, req.Snapshots[i])
			continue
		}
		p.stats.Served++
		out = append(out, in)
	}
	p.mu.Unlock()

	p.enqueue(askAbout)
	return out, nil
}

// enqueue hands a round to the background worker, newest snapshots winning.
func (p *Planner) enqueue(snaps []contract.Snapshot) {
	if len(snaps) == 0 {
		return
	}
	if n := p.opts.MaxBotsPerRound; n > 0 && len(snaps) > n {
		// Truncation is deliberate and the remainder is NOT carried over: the
		// bots left out are asked about on the next tick with a fresher
		// snapshot, which is better than planning them now from one that will
		// be stale by the time the model answers.
		snaps = snaps[:n]
	}

	p.mu.Lock()
	for i := range snaps {
		p.inFlight[snaps[i].Bot] = true
	}
	p.mu.Unlock()

	select {
	case p.queue <- snaps:
		p.mu.Lock()
		p.stats.Queued++
		p.mu.Unlock()
	default:
		// The worker is still busy. Dropping is right: a queue of rounds is a
		// queue of increasingly stale snapshots, and the next tick will offer
		// the same bots with better data.
		p.mu.Lock()
		p.stats.Dropped++
		for i := range snaps {
			delete(p.inFlight, snaps[i].Bot)
		}
		p.mu.Unlock()
	}
}

func (p *Planner) run() {
	defer p.wg.Done()
	for snaps := range p.queue {
		p.round(snaps)
	}
}

func (p *Planner) round(snaps []contract.Snapshot) {
	// Background context, not a request's: this work outlives the request that
	// prompted it, which is the entire point of the lane.
	ctx, cancel := context.WithTimeout(context.Background(), p.opts.Timeout)
	defer cancel()

	// The request is rebuilt from the snapshots rather than kept from the
	// caller, so expiry is stamped from the observation the plan is actually
	// based on.
	req := planner.Request{
		Snapshots:   snaps,
		ServerNowMS: serverNow(snaps),
		IntentTTLMS: intentTTL(snaps),
	}
	intents, err := p.slow.Plan(ctx, req)

	p.mu.Lock()
	for i := range snaps {
		delete(p.inFlight, snaps[i].Bot)
	}
	for _, in := range intents {
		// Validated here rather than trusted: this is the same boundary
		// Fallback applies to a primary's output, and skipping it would let a
		// malformed intent sit in the ready set being served to one bot for as
		// long as it took to expire.
		if in.Validate() != nil {
			continue
		}
		p.ready[in.Bot] = in
	}
	p.mu.Unlock()

	if err != nil && p.opts.OnError != nil {
		p.opts.OnError(err)
	}
}

// Stats returns a snapshot of the counters.
func (p *Planner) Stats() Stats {
	if p == nil {
		return Stats{}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.stats
}

// Stop drains and waits. Safe to call more than once.
func (p *Planner) Stop() {
	if p == nil {
		return
	}
	p.stop.Do(func() { close(p.queue) })
	p.wg.Wait()
}

// serverNow is the newest observation in the round, used as the request's clock.
func serverNow(snaps []contract.Snapshot) int64 {
	var newest int64
	for i := range snaps {
		if snaps[i].ObservedAtMS > newest {
			newest = snaps[i].ObservedAtMS
		}
	}
	return newest
}

// intentTTL is how long the intents from this round stay valid.
//
// Fixed rather than inherited from the request that prompted the round, because
// that request is already over by the time this runs. It has to exceed the
// model's latency or every answer expires before it can be served -- which is
// the failure this package exists to avoid, reintroduced one layer down.
const defaultRoundTTLMS = 60_000

func intentTTL([]contract.Snapshot) int64 { return defaultRoundTTLMS }
