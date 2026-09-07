package rule_test

import (
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/identity"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/memory"
)

// The trait name is spelled in two packages, and this is the guard that stops
// them drifting apart.
//
// memory writes the trait and identity reads it, but memory cannot import
// identity: identity will want to read history as soon as traits depend on more
// than boldness, and that would be an import cycle. So the constant is
// duplicated deliberately -- and a duplicated constant with nothing checking it
// is a bug waiting for someone to fix a typo in one place.
//
// The failure this prevents is silent in the worst way: the learner would write
// "boldnes", the resolver would look for "boldness", find nothing, fall back to
// the derived value, and every bot would quietly stop learning while both halves
// of the system reported themselves healthy.
//
// It lives in this package because rule is the one that already imports both.
func TestTraitNamesAgreeAcrossPackages(t *testing.T) {
	if identity.TraitBoldness != memory.TraitBoldness {
		t.Fatalf("identity writes %q but memory writes %q; a bot would learn into a "+
			"trait nobody reads", identity.TraitBoldness, memory.TraitBoldness)
	}
}

// The bands must agree too. If memory clamped to a wider range than identity
// accepts, learning would write values the resolver silently clamps back --
// bots would appear to learn and then not change.
func TestTraitBandsAgreeAcrossPackages(t *testing.T) {
	// identity clamps stored values into the same range Derive produces, and
	// memory clamps what it writes. Both must be the same interval or one of
	// them is doing nothing.
	if memory.BoldnessFloor != 0.5 || memory.BoldnessCeiling != 1.5 {
		t.Fatalf("memory clamps to [%v, %v]; identity.Derive produces [0.5, 1.5]",
			memory.BoldnessFloor, memory.BoldnessCeiling)
	}
	// Proven against the real derivation rather than a repeated literal: if
	// Derive's range ever moves, this fails rather than quietly disagreeing.
	for i := 0; i < 256; i++ {
		s := identity.Derive(uuidN(i)).RangeScale()
		if s < memory.BoldnessFloor || s > memory.BoldnessCeiling {
			t.Fatalf("Derive produced %v, outside memory's clamp [%v, %v]",
				s, memory.BoldnessFloor, memory.BoldnessCeiling)
		}
	}
}
