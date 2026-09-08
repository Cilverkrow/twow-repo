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
	"sort"
	"sync"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/llm"
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
	// MaxAttempts bounds tries per round when the provider says "later".
	// Zero means 3. One disables retrying.
	MaxAttempts int
	// MinInterval is the floor between background calls -- a rate limit
	// expressed as spacing rather than as a bucket, because rounds are already
	// the unit of calling and one knob is easier to reason about than three.
	// Zero means no floor.
	MinInterval time.Duration
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
	// lastAsked is when each bot was last handed to the model, in the
	// server's clock. It is what makes attention FAIR.
	//
	// Without it the round was the first N of the batch, and the worldserver
	// sends bots in a stable order -- so the same sixteen bots received every
	// inference the service ever performed and the rest of the population was
	// never planned for by the model at all. That is invisible from outside:
	// the metrics show inference happening, at the configured rate, forever.
	lastAsked map[contract.BotID]int64
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
	// Retried is attempts made after a provider asked us to wait. Rising with
	// no matching rise in Served means the endpoint is rate limiting harder
	// than this lane can absorb.
	Retried uint64
	// Throttled is rounds delayed by MinInterval.
	Throttled uint64
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
	if opts.MaxAttempts <= 0 {
		opts.MaxAttempts = 3
	}
	if opts.QueueDepth <= 0 {
		opts.QueueDepth = 4
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}

	p := &Planner{
		slow:      slow,
		opts:      opts,
		queue:     make(chan []contract.Snapshot, opts.QueueDepth),
		ready:     make(map[contract.BotID]contract.Intent),
		inFlight:  make(map[contract.BotID]bool),
		lastAsked: make(map[contract.BotID]int64),
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

	p.enqueue(askAbout, now)
	return out, nil
}

// enqueue hands a round to the background worker, choosing who gets asked.
func (p *Planner) enqueue(snaps []contract.Snapshot, now int64) {
	if len(snaps) == 0 {
		return
	}

	p.mu.Lock()
	if n := p.opts.MaxBotsPerRound; n > 0 && len(snaps) > n {
		// LEAST RECENTLY ASKED first, not the first N of the batch.
		//
		// The batch arrives in a stable order, so taking a prefix means the same
		// bots are chosen every single time and everyone else is never planned
		// for by the model. Sorting by when each bot was last asked spreads the
		// budget across the population instead: a bot that has never been asked
		// sorts first (zero), and one asked a moment ago sorts last.
		//
		// Stable sort with the bot id as the tie-break, so a tie -- which is the
		// normal case on the first tick, when nobody has been asked -- resolves
		// the same way every run rather than by map iteration order.
		sort.SliceStable(snaps, func(a, b int) bool {
			la, lb := p.lastAsked[snaps[a].Bot], p.lastAsked[snaps[b].Bot]
			if la != lb {
				return la < lb
			}
			if snaps[a].Bot.Realm != snaps[b].Bot.Realm {
				return snaps[a].Bot.Realm < snaps[b].Bot.Realm
			}
			return snaps[a].Bot.GUID < snaps[b].Bot.GUID
		})
		// The remainder is NOT carried over: those bots are asked on a later
		// tick with a fresher snapshot, which beats planning them now from one
		// that will be stale by the time the model answers.
		snaps = snaps[:n]
	}

	for i := range snaps {
		p.inFlight[snaps[i].Bot] = true
		if now > 0 {
			p.lastAsked[snaps[i].Bot] = now
		}
	}
	p.forgetDepartedLocked(now)
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
		// lastAsked is deliberately NOT rolled back. The bot was chosen fairly
		// and lost to a full queue; rewinding it would make the same bot win
		// the next round too, and a permanently busy worker would starve the
		// population exactly as the old prefix did.
		p.mu.Unlock()
	}
}

func (p *Planner) run() {
	defer p.wg.Done()
	var last time.Time
	for snaps := range p.queue {
		// Spacing is applied HERE rather than at enqueue, so a rate limit delays
		// inference without delaying the caller: Plan has already returned by
		// the time this waits.
		if p.opts.MinInterval > 0 && !last.IsZero() {
			if wait := p.opts.MinInterval - p.opts.Now().Sub(last); wait > 0 {
				p.mu.Lock()
				p.stats.Throttled++
				p.mu.Unlock()
				time.Sleep(wait)
			}
		}
		last = p.opts.Now()
		p.round(snaps)
	}
}

// attempt calls the slow planner, waiting out a provider that asked us to.
//
// Retrying is affordable HERE and nowhere else. The planner refuses to retry
// inside a call that may be racing a tick, because the deterministic fallback
// needs the remaining budget -- but this runs between ticks with a timeout of
// its own, so the only thing a wait costs is one round arriving later, which is
// the trade this whole lane already makes.
//
// Only a provider's own "later" is retried. A 400, a bad key or a missing model
// fails identically forever, and retrying those turns one mistake into a stream
// of them -- billed, on a metered endpoint.
func (p *Planner) attempt(ctx context.Context, req planner.Request) ([]contract.Intent, error) {
	var lastErr error
	for attempt := 0; attempt < p.opts.MaxAttempts; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				// The round's own deadline. Returning the provider's error
				// rather than the context's keeps the log's reason the thing
				// that actually went wrong.
				return nil, lastErr
			case <-time.After(backoff(attempt, llm.RetryAfter(lastErr))):
			}
			p.mu.Lock()
			p.stats.Retried++
			p.mu.Unlock()
		}

		intents, err := p.slow.Plan(ctx, req)
		if err == nil || !llm.Retryable(err) {
			return intents, err
		}
		lastErr = err
	}
	return nil, lastErr
}

// backoff is how long to wait before trying again.
//
// The provider's instruction wins whenever it gave one. A backoff of our own
// choosing that is shorter than what it asked for is how a rate limit becomes a
// ban, and it is the one number here we have no business guessing at.
func backoff(attempt int, requested time.Duration) time.Duration {
	if requested > 0 {
		if requested > maxBackoff {
			return maxBackoff
		}
		return requested
	}
	// Otherwise double from a second, capped. Not jittered: this is one process
	// making one call at a time, so there is no herd to spread, and unjittered
	// backoff is easier to follow in a log.
	d := time.Second << (attempt - 1)
	if d > maxBackoff {
		return maxBackoff
	}
	return d
}

// maxBackoff bounds a wait, including one the provider asked for. A round that
// sat for ten minutes would answer from a snapshot the world has long since
// moved past, and its intent would expire unused anyway.
const maxBackoff = 30 * time.Second

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
	intents, err := p.attempt(ctx, req)

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

// forgetDepartedLocked bounds lastAsked. Caller holds the mutex.
//
// The map grows with every bot ever seen, and bots log out, change realm or are
// deleted -- so without this it is a slow leak keyed by something that never
// comes back. Entries are dropped once they are older than the window, which
// costs a bot its place in the queue at worst: it sorts first next time, which
// is exactly what a bot nobody has asked about in an hour deserves.
func (p *Planner) forgetDepartedLocked(now int64) {
	if now <= 0 || len(p.lastAsked) <= lastAskedSoftLimit {
		return
	}
	for bot, at := range p.lastAsked {
		if now-at > lastAskedRetentionMS {
			delete(p.lastAsked, bot)
		}
	}
}

const (
	// lastAskedSoftLimit is when pruning starts. Comfortably above any realistic
	// bot population, so the scan is rare rather than per-tick.
	lastAskedSoftLimit = 8192
	// lastAskedRetentionMS is how long a bot is remembered after it was last
	// asked about. An hour: long enough that a bot logging out and back in keeps
	// its place, short enough that a departed one does not linger for the life
	// of the process.
	lastAskedRetentionMS = 60 * 60 * 1000
)

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
