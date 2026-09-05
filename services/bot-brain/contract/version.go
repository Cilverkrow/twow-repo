// Package contract defines the wire contract between the worldserver (C++,
// mod-playerbots) and the out-of-process bot brain.
//
// It is the deliverable of ARCH-001. Everything else in this service is an
// implementation detail that may be rewritten; this package is the thing the
// C++ side is allowed to depend on.
//
// # The two halves
//
// A [Snapshot] is what the server tells the brain about one bot and the small
// slice of the world that matters for a *slow* decision. A [Intent] is what the
// brain suggests that bot should do next. Both travel inside a batch envelope
// ([PlanRequest] / [PlanResponse]) because at ~1000 bots a per-bot round trip
// is not affordable.
//
// # Non-goals, stated so nobody designs against them
//
//   - This is not a combat contract. Tier 0 (in-core C++) keeps every per-tick
//     decision. See the tier table in docs/issues/30-deferred-architecture.md.
//   - Intents are *advisory*. The worldserver validates every intent against
//     live state and may reject it. A rejected intent is a normal outcome, not
//     an error.
//   - No intent can create, delete, relocate, re-roll, log out or substitute a
//     bot. That is ADR-0024 invariant 1, and it is enforced here by the type
//     system: no such [IntentKind] exists, and one cannot be added without
//     changing this file.
//
// # Units and frames, once, for the whole package
//
//   - Distances and coordinates are in game yards (the units mangos itself
//     uses), in the map-local coordinate frame identified by Position.MapID.
//     There is no global frame; comparing coordinates across MapIDs is a bug.
//   - Angles are radians in [0, 2*Pi), counter-clockwise, 0 = +X, matching
//     Object::GetOrientation().
//   - Times are Unix milliseconds UTC. They are the *server's* clock. The brain
//     must never assume its own clock agrees; see [PlanRequest.ObservedAtMS].
//   - Percentages are float64 in [0, 100], not [0, 1].
//   - Durations named *MS are milliseconds.
//
// # Absence
//
// Every optional field documents what its zero value means. The rule is that a
// zero value must be safe: a planner that sees a field it did not get must be
// able to fall through to a conservative decision rather than guess. Optional
// *scalars* that have a meaningful zero (a level of 0, a count of 0) are
// pointers so that "absent" and "zero" stay distinguishable on the wire.
package contract

import (
	"fmt"
	"strconv"
	"strings"
)

// Contract version. This is deliberately a *contract* version, not the service
// version and not a build number. It changes only when the shape of what
// crosses the wire changes.
//
// Semantics, which the C++ side may rely on:
//
//   - MAJOR changes are breaking. Fields are removed or repurposed, an
//     [IntentKind] changes meaning, or units change. A peer that speaks a
//     different major is refused with [ErrVersionSkew] rather than served
//     wrong data. Refusal is the correct outcome: the worldserver falls back to
//     tier 0 in-core AI, which is always available.
//   - MINOR changes are additive and backward compatible. New optional fields,
//     new [IntentKind] values. An older peer may ignore what it does not know;
//     a newer peer must treat the missing additions as absent.
//
// The C++ side and this service are deployed separately and WILL skew. The
// design assumption is that skew is normal, not exceptional.
const (
	VersionMajor = 1
	VersionMinor = 1
)

// Version is the canonical "MAJOR.MINOR" string carried on every request and
// response.
var Version = fmt.Sprintf("%d.%d", VersionMajor, VersionMinor)

// SupportedMajors lists every major version this build can serve. When a v2 is
// introduced, v1 stays here for as long as a deployed worldserver might still
// speak it. Removing an entry is a deployment decision, not a code cleanup.
var SupportedMajors = []int{1}

// ParsedVersion is a decoded contract version.
type ParsedVersion struct {
	Major int
	Minor int
}

func (v ParsedVersion) String() string { return strconv.Itoa(v.Major) + "." + strconv.Itoa(v.Minor) }

// ParseVersion parses "MAJOR.MINOR". A missing or malformed version is an
// error, never a silent default: guessing the peer's version is exactly how a
// skew bug becomes a wrong-behaviour bug.
func ParseVersion(s string) (ParsedVersion, error) {
	if s == "" {
		return ParsedVersion{}, fmt.Errorf("%w: empty contract_version (server must send %q)", ErrVersionSkew, Version)
	}
	parts := strings.SplitN(s, ".", 3)
	if len(parts) != 2 {
		return ParsedVersion{}, fmt.Errorf("%w: malformed contract_version %q, want MAJOR.MINOR", ErrVersionSkew, s)
	}
	major, err := strconv.Atoi(parts[0])
	if err != nil || major < 0 {
		return ParsedVersion{}, fmt.Errorf("%w: malformed major in contract_version %q", ErrVersionSkew, s)
	}
	minor, err := strconv.Atoi(parts[1])
	if err != nil || minor < 0 {
		return ParsedVersion{}, fmt.Errorf("%w: malformed minor in contract_version %q", ErrVersionSkew, s)
	}
	return ParsedVersion{Major: major, Minor: minor}, nil
}

// Negotiate decides whether a peer speaking version s can be served.
//
// It returns the version the response should be stamped with. The rules:
//
//	same major, peer minor <= ours   -> serve, stamp with the peer's minor.
//	                                    We must not send fields the peer's
//	                                    decoder predates; stamping down tells
//	                                    honest planners to stay conservative.
//	same major, peer minor >  ours   -> serve, stamp with OUR minor. The peer
//	                                    is newer and sent fields we ignore.
//	                                    This is the common skew direction
//	                                    (C++ deployed ahead of the service).
//	different major                  -> ErrVersionSkew. Refuse.
func Negotiate(s string) (ParsedVersion, error) {
	pv, err := ParseVersion(s)
	if err != nil {
		return ParsedVersion{}, err
	}
	supported := false
	for _, m := range SupportedMajors {
		if m == pv.Major {
			supported = true
			break
		}
	}
	if !supported {
		return ParsedVersion{}, fmt.Errorf("%w: peer speaks contract major %d, this build serves %v",
			ErrVersionSkew, pv.Major, SupportedMajors)
	}
	effective := ParsedVersion{Major: pv.Major, Minor: pv.Minor}
	if pv.Minor > VersionMinor {
		effective.Minor = VersionMinor
	}
	return effective, nil
}
