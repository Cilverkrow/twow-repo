package identity

import (
	"context"
	"math"
)

// Store is where traits that have CHANGED live. It is deliberately a narrow
// read interface: the planner asks for the traits of the bots in front of it and
// gets back only those that differ from their derived values.
//
// Implementations must key on the UUID alone. cv_brain.bot_trait has no realm or
// guid column on purpose -- the planner is the process that talks to an
// inference endpoint, and the UUID exists to keep the character's game identity
// away from it.
//
// A Store is allowed to fail. See [Resolver.Resolve]: a store that is down
// produces derived traits, which makes bots generic rather than broken.
type Store interface {
	// Load returns the stored traits for the given UUIDs. Missing bots and
	// missing traits are simply absent from the result -- absence means "not
	// changed yet", which is the normal case and not an error.
	Load(ctx context.Context, uuids []string) (map[string]map[string]float64, error)
}

// Resolver turns UUIDs into traits, preferring what a bot has become over what
// it was born as.
//
// A nil Store is valid and means derived-only. That is the configuration the
// service runs in when no database is configured, and it is a supported mode
// rather than a degraded one: bots still differ from each other, they just do
// not change.
type Resolver struct {
	Store Store

	// OnStoreError is called when the store fails, once per failed batch. The
	// resolver does NOT log for itself, because the planner is a pure decision
	// path and giving it a logger is how a testable function stops being one.
	OnStoreError func(error)
}

// Resolve returns traits for each requested UUID.
//
// Every UUID gets an entry, always. A caller that has to distinguish "absent
// because unminted" from "absent because the store was down" would end up
// reimplementing the fallback at every call site, and one of those copies would
// eventually get it wrong.
//
// The order of preference is: stored value, then derived value, then Neutral for
// an empty UUID. A store failure is not propagated -- it degrades to derived and
// reports through OnStoreError, because a bot that cannot be planned for is
// worse than a bot planned for generically. This is the same reasoning as
// ADR-0012's fail-closed admission, applied to a value that has a safe default:
// admission fails closed because there is no safe way to guess a plan, whereas
// there IS a safe way to guess a trait, and it is the one the bot was born with.
func (r *Resolver) Resolve(ctx context.Context, uuids []string) map[string]Traits {
	out := make(map[string]Traits, len(uuids))
	for _, u := range uuids {
		out[u] = Derive(u)
	}
	if r == nil || r.Store == nil || len(uuids) == 0 {
		return out
	}

	stored, err := r.Store.Load(ctx, uuids)
	if err != nil {
		if r.OnStoreError != nil {
			r.OnStoreError(err)
		}
		return out
	}

	for uuid, traits := range stored {
		if uuid == "" {
			// An unminted bot has no identity to have changed. A row keyed on
			// the empty string is corrupt data, not a bot.
			continue
		}
		base, ok := out[uuid]
		if !ok {
			// The store answered about a bot nobody asked about. Ignore it
			// rather than widen the result: the caller allocated for what it
			// requested, and an unexpected key here would be a silent leak of
			// one batch's work into another's.
			continue
		}
		out[uuid] = base.apply(traits)
	}
	return out
}

// TraitBoldness is the stored name for [Traits.Boldness].
//
// The vocabulary is enforced here rather than in the schema. bot_trait.trait is
// an unconstrained varchar so that adding a trait needs no migration, which
// means a typo reaches this function -- and an unknown name must be DROPPED, not
// guessed at. Silently applying "boldnes" to nothing is correct; applying it to
// Boldness because it looks close would be a bot whose personality depends on a
// spelling mistake.
const TraitBoldness = "boldness"

// apply overlays stored values onto derived ones.
//
// Values are clamped to the same band Derive produces. A row written by hand, or
// by a future learning rule with a bug, must not be able to give a bot a travel
// range of zero or of ten times the configured ceiling: the operator's bound
// stays the operator's bound, and the worst a bad row can do is make one bot
// unusually bold or unusually timid.
func (t Traits) apply(stored map[string]float64) Traits {
	if v, ok := stored[TraitBoldness]; ok {
		t.Boldness = clamp(v, boldnessMin, boldnessMax)
	}
	return t
}

const (
	boldnessMin = 0.5
	boldnessMax = 1.5
)

func clamp(v, lo, hi float64) float64 {
	if math.IsNaN(v) {
		// NaN compares false against everything, so it would slip through a
		// naive bounds check and then poison every distance comparison it
		// touched. Treat it as "no opinion" and fall back to the middle.
		return (lo + hi) / 2
	}
	return math.Min(math.Max(v, lo), hi)
}
