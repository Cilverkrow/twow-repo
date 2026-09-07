package memory

import "context"

// TraitWriter records a trait that experience has changed.
//
// Deliberately narrow: this package must be able to make a bot more cautious
// without being able to do anything else to it.
type TraitWriter interface {
	Set(ctx context.Context, uuid, trait string, value float64, reason string) error
}

// TraitReader is the current value, so a change is a step from where the bot is
// rather than from where it was born.
type TraitReader interface {
	Load(ctx context.Context, uuids []string) (map[string]map[string]float64, error)
}

// Learner turns what happened to a bot into what the bot becomes.
//
// This is the half of identity that a hash cannot provide. Derived traits make
// every bot different; only this makes a bot different LATER, and for a reason
// that can be read back -- every write records why in words.
//
// It runs off the request path, behind [AsyncRecorder], because it reads and
// writes the database and must never sit inside a planning deadline.
type Learner struct {
	Reader Reader
	Traits TraitWriter
	Values TraitReader
	// Derived is the trait a bot is born with, used when it has no stored value
	// yet. Without it the first adjustment would step from an assumed default
	// and quietly erase the bot's derived personality on its first bad trip.
	Derived func(uuid string) float64
	// OnChange is called when a trait actually moves. Nil means silence.
	OnChange func(uuid, trait string, from, to float64, reason string)
}

const (
	// BoldnessStep is how far one adjustment moves a bot.
	//
	// Small on purpose. A personality that swings on a bad afternoon is not a
	// personality, and the whole point of storing this is that it accumulates
	// slowly enough to mean something. At 0.05 a bot needs many consistent
	// failures to travel meaningfully less far, and a run of luck cannot undo
	// who it is.
	BoldnessStep = 0.05

	// BoldnessFloor and BoldnessCeiling are the same band Derive produces, so
	// learning can move a bot within the range of possible bots and never
	// outside it. A bot that learned its way to a travel range of zero would be
	// broken, not cautious.
	BoldnessFloor   = 0.5
	BoldnessCeiling = 1.5

	// LearnAfterFailures is how many discouraging outcomes in the recent window
	// it takes to move a bot at all.
	//
	// Higher than DiscouragedThreshold, which only stops one POI being offered.
	// Avoiding a place is cheap and reversible; changing who a bot is should
	// need more evidence than that.
	LearnAfterFailures = 4

	// LearnAfterSuccesses is the counterweight. Without it boldness only ever
	// falls: every bot would drift to the floor, because failures are recorded
	// and recoveries are not, and a system that can only lose confidence is not
	// learning, it is decaying.
	LearnAfterSuccesses = 6
)

// Observe updates a bot's traits from its recent history.
//
// Called after an observation is stored, so the history it reads includes the
// event that triggered it. Returns nil when nothing changed, which is the
// overwhelmingly common case.
func (l *Learner) Observe(ctx context.Context, uuid string) error {
	if l == nil || l.Reader == nil || l.Traits == nil || uuid == "" {
		return nil
	}

	recent, err := l.Reader.Recent(ctx, []string{uuid}, DefaultRecentLimit)
	if err != nil {
		return err
	}
	observations := recent[uuid]
	if len(observations) == 0 {
		return nil
	}

	failures, successes := 0, 0
	for _, o := range observations {
		switch {
		case o.Discouraging():
			failures++
		case o.Result == "completed":
			successes++
		}
	}

	// Direction, or nothing. Deliberately not a formula over the ratio: a
	// continuous function of a noisy count moves every bot a little all the
	// time, which is drift dressed up as learning.
	var delta float64
	var why string
	switch {
	case failures >= LearnAfterFailures:
		delta = -BoldnessStep
		why = "kept failing to reach places"
	case successes >= LearnAfterSuccesses:
		delta = BoldnessStep
		why = "has been getting where it means to go"
	default:
		return nil
	}

	current := l.currentBoldness(ctx, uuid)
	next := clampBoldness(current + delta)
	if next == current {
		// Already at the bound. Writing would churn the row and its reason for
		// no change a reader could see.
		return nil
	}

	if err := l.Traits.Set(ctx, uuid, TraitBoldness, next, why); err != nil {
		return err
	}
	if l.OnChange != nil {
		l.OnChange(uuid, TraitBoldness, current, next, why)
	}
	return nil
}

// currentBoldness is the stored value, or the derived one, or the middle.
//
// A failed read falls back rather than aborting: the trait store is allowed to
// be down, and a bot that cannot be read is better nudged from its derived
// personality than left un-adjusted forever.
func (l *Learner) currentBoldness(ctx context.Context, uuid string) float64 {
	if l.Values != nil {
		if stored, err := l.Values.Load(ctx, []string{uuid}); err == nil {
			if v, ok := stored[uuid][TraitBoldness]; ok {
				return clampBoldness(v)
			}
		}
	}
	if l.Derived != nil {
		return clampBoldness(l.Derived(uuid))
	}
	return (BoldnessFloor + BoldnessCeiling) / 2
}

// TraitBoldness is the stored name of the trait this package adjusts. It must
// match identity.TraitBoldness; the constant is duplicated rather than imported
// so that memory does not depend on identity, which would make the dependency
// cycle the moment identity wants to read history.
const TraitBoldness = "boldness"

func clampBoldness(v float64) float64 {
	if v < BoldnessFloor {
		return BoldnessFloor
	}
	if v > BoldnessCeiling {
		return BoldnessCeiling
	}
	return v
}
