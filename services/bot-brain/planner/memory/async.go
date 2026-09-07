package memory

import (
	"context"
	"sync"
)

// AsyncRecorder writes observations off the request path.
//
// Recording must not sit inside a planning deadline. The worldserver is waiting
// on that response to decide what a thousand bots do next, and a database that
// has gone slow would turn "the brain remembers things" into "the brain makes
// every bot late" -- trading the feature's benefit for a regression in the one
// property the whole service is built around.
//
// So writes are queued and drained by workers, and the queue is BOUNDED. An
// unbounded one would convert a stalled database into unbounded memory growth,
// which is the same outage arriving later and harder to diagnose.
//
// Dropping is therefore a designed behaviour, not a failure: losing an
// observation costs a little history, while blocking the planner costs the
// server. Drops are counted so the trade is visible rather than silent.
type AsyncRecorder struct {
	store Recorder

	queue chan entry
	wg    sync.WaitGroup

	// OnError is called for a write that failed, and for a drop (with a nil
	// error and a non-zero dropped count). Nil means silence. The recorder does
	// not log for itself: it is used from the request path, and a component that
	// logs per-observation would be a log flood the first time the database
	// blinks.
	OnError func(err error, dropped uint64)

	mu      sync.Mutex
	dropped uint64

	stopOnce sync.Once
}

type entry struct {
	uuid string
	obs  Observation
}

// NewAsyncRecorder starts workers draining into store.
//
// A nil store yields a nil recorder, which is safe to call: that is the
// configuration the service runs in with no database, and it must be a normal
// mode rather than a branch at every call site.
func NewAsyncRecorder(store Recorder, queueSize, workers int) *AsyncRecorder {
	if store == nil {
		return nil
	}
	if queueSize <= 0 {
		queueSize = 4096
	}
	if workers <= 0 {
		workers = 2
	}

	r := &AsyncRecorder{
		store: store,
		queue: make(chan entry, queueSize),
	}
	for i := 0; i < workers; i++ {
		r.wg.Add(1)
		go r.drain()
	}
	return r
}

// Record queues one observation. It never blocks and never fails.
//
// The context argument is deliberately ignored for the write itself: the caller's
// context is the REQUEST's, and cancelling it must not cancel a write that is
// no longer part of that request. The worker uses its own bounded timeout.
func (r *AsyncRecorder) Record(_ context.Context, uuid string, o Observation) error {
	if r == nil || uuid == "" {
		return nil
	}
	select {
	case r.queue <- entry{uuid: uuid, obs: o}:
	default:
		r.mu.Lock()
		r.dropped++
		dropped := r.dropped
		r.mu.Unlock()
		if r.OnError != nil {
			r.OnError(nil, dropped)
		}
	}
	return nil
}

// Dropped is how many observations have been discarded because the queue was
// full.
func (r *AsyncRecorder) Dropped() uint64 {
	if r == nil {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.dropped
}

// Stop drains the queue and waits for the workers.
//
// Called on shutdown so observations already queued are not lost to a graceful
// restart -- the one case where losing them is both avoidable and annoying,
// because a restart is exactly when a bot's recent history matters most.
func (r *AsyncRecorder) Stop() {
	if r == nil {
		return
	}
	r.stopOnce.Do(func() { close(r.queue) })
	r.wg.Wait()
}

func (r *AsyncRecorder) drain() {
	defer r.wg.Done()
	for e := range r.queue {
		ctx, cancel := context.WithTimeout(context.Background(), RecordTimeout)
		err := r.store.Record(ctx, e.uuid, e.obs)
		cancel()
		if err != nil && r.OnError != nil {
			r.OnError(err, 0)
		}
	}
}
