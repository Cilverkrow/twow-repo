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

	// onError is called for a write that failed, and for a drop (with a nil
	// error and a non-zero dropped count). Nil means silence. The recorder does
	// not log for itself: it is used from the request path, and a component that
	// logs per-observation would be a log flood the first time the database
	// blinks.
	//
	// Constructor-only, deliberately unexported. As an exported field it was a
	// data race by construction: the workers that read it are started by
	// NewAsyncRecorder, so any caller assigning it afterwards -- which is the
	// obvious way to use a struct field -- races every drain goroutine.
	onError func(err error, dropped uint64)

	// afterRecord runs on the worker once an observation is safely stored. It
	// is where learning happens: reading a bot's history and adjusting its
	// traits is more database work, and it belongs on this side of the queue
	// with the write, not on the planning path with the read.
	afterRecord func(ctx context.Context, uuid string)

	mu      sync.Mutex
	dropped uint64

	stopOnce sync.Once
}

type entry struct {
	uuid string
	obs  Observation
}

// AsyncOptions configures an [AsyncRecorder].
//
// A struct rather than positional arguments: OnError and AfterRecord are both
// optional callbacks of similar shape, and a call site passing two bare funcs
// is one transposition away from silently swapping them.
type AsyncOptions struct {
	// QueueSize bounds pending observations. Zero means 4096.
	QueueSize int
	// Workers drain the queue. Zero means 2.
	Workers int
	// OnError reports a failed write, and a drop (nil error, non-zero count).
	OnError func(err error, dropped uint64)
	// AfterRecord runs once an observation is stored, for learning.
	AfterRecord func(ctx context.Context, uuid string)
}

// NewAsyncRecorder starts workers draining into store.
//
// A nil store yields a nil recorder, which is safe to call: that is the
// configuration the service runs in with no database, and it must be a normal
// mode rather than a branch at every call site.
func NewAsyncRecorder(store Recorder, opts AsyncOptions) *AsyncRecorder {
	if store == nil {
		return nil
	}
	if opts.QueueSize <= 0 {
		opts.QueueSize = 4096
	}
	if opts.Workers <= 0 {
		opts.Workers = 2
	}

	r := &AsyncRecorder{
		store:       store,
		queue:       make(chan entry, opts.QueueSize),
		onError:     opts.OnError,
		afterRecord: opts.AfterRecord,
	}
	for i := 0; i < opts.Workers; i++ {
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
		if r.onError != nil {
			r.onError(nil, dropped)
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
		if err != nil {
			if r.onError != nil {
				r.onError(err, 0)
			}
			// Nothing was stored, so there is nothing new to learn from. Running
			// the hook anyway would draw a conclusion from a history missing the
			// event that prompted it.
			cancel()
			continue
		}
		if r.afterRecord != nil {
			r.afterRecord(ctx, e.uuid)
		}
		cancel()
	}
}
