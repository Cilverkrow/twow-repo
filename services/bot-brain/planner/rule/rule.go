// Package rule is the deterministic planner: the default, the fallback, and the
// thing every other planner is measured against.
//
// It has no network dependency, no clock dependency (expiry comes from the
// server's clock in the request) and no randomness. The same snapshot always
// produces the same intent, which is what makes it testable without a server, a
// database or a game -- the harness requirement ARCH-001 puts first.
//
// The policy it implements is deliberately boring. It is a priority ladder, and
// the last rung is always [contract.IntentIdle], so there is no snapshot for
// which this planner has nothing to say.
package rule

import (
	"context"
	"sort"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
)

// Thresholds are the tunable numbers of the ladder. They are a struct rather
// than constants so tests can pin them and so an operator can change policy
// without a rebuild -- which is, after all, the entire motivation for this
// service existing (326 seconds of C++ rebuild per behaviour change).
type Thresholds struct {
	// RestBelowHealthPct: below this, a bot out of combat rests instead of
	// travelling. 0 disables the rung.
	RestBelowHealthPct float64
	// RepairBelowDurabilityPct: below this, a bot seeks a repair POI.
	RepairBelowDurabilityPct float64
	// VendorWhenFreeBagSlotsAtMost: at or below this many free slots, a bot
	// seeks a vendor.
	VendorWhenFreeBagSlotsAtMost uint32
	// MaxTravelYards: POIs further than this are not proposed, because a very
	// long walk is a decision the server's own travel system should make.
	// 0 means no limit.
	MaxTravelYards float64
}

// DefaultThresholds are conservative on purpose: this planner is the fallback,
// and a fallback that proposes ambitious things when the clever planner is down
// is a fallback that makes outages worse.
func DefaultThresholds() Thresholds {
	return Thresholds{
		RestBelowHealthPct:           45,
		RepairBelowDurabilityPct:     25,
		VendorWhenFreeBagSlotsAtMost: 1,
		MaxTravelYards:               1500,
	}
}

// Planner is the deterministic planner.
type Planner struct {
	Th Thresholds
}

// New returns a rule planner with the given thresholds. A zero Thresholds means
// [DefaultThresholds].
func New(th Thresholds) *Planner {
	if th == (Thresholds{}) {
		th = DefaultThresholds()
	}
	return &Planner{Th: th}
}

func (p *Planner) Name() string { return "rule" }

// Ready is always true. That is the point of this planner: it is the thing that
// is always available, so the service's readiness never depends on a model.
func (p *Planner) Ready() bool { return true }

// Plan answers for every snapshot in the batch. It never returns an error: a
// snapshot it cannot make sense of gets [contract.IntentIdle], because "keep
// doing what the in-core AI was doing" is always a safe answer and refusing to
// answer would leave the bot in exactly the same state anyway, minus the
// telemetry.
func (p *Planner) Plan(ctx context.Context, req planner.Request) ([]contract.Intent, error) {
	out := make([]contract.Intent, 0, len(req.Snapshots))
	expiry := req.ExpiryMS()
	for i := range req.Snapshots {
		// Respect cancellation even here. This planner is fast, but it is also
		// the fallback for a whole batch, and a 2000-snapshot batch under an
		// already-blown deadline should stop rather than finish out of pride.
		select {
		case <-ctx.Done():
			return out, ctx.Err()
		default:
		}
		in := p.planOne(&req.Snapshots[i])
		in.ExpiresAtMS = expiry
		if err := in.Validate(); err != nil {
			// Belt and braces: a bug in the ladder must not ship a malformed
			// intent. Degrade to idle, which cannot be malformed.
			in = contract.Idle(req.Snapshots[i].Bot, in.IntentID, p.Name(), "rule planner produced an invalid intent")
			in.ExpiresAtMS = expiry
		}
		out = append(out, in)
	}
	return out, nil
}

// planOne is the priority ladder. Read it top to bottom; the first rung that
// matches wins.
func (p *Planner) planOne(s *contract.Snapshot) contract.Intent {
	id := planner.NewIntentID()
	idle := func(why string) contract.Intent {
		return contract.Idle(s.Bot, id, p.Name(), why)
	}

	// Rung 0: snapshots we must not act on at all.
	if err := s.Validate(); err != nil {
		return idle("snapshot failed validation")
	}
	if s.Vit.IsDead {
		// Corpse runs and resurrection are tier-0. Anything else here would be
		// a suggestion the server rejects a moment later.
		return idle("bot is dead; recovery is an in-core concern")
	}
	if s.Vit.InCombat {
		return idle("bot is in combat; planning is tier 0 until it ends")
	}
	if s.Pos.InstanceID != 0 {
		// Travel out of an instance is never this planner's call.
		return idle("bot is inside an instance")
	}
	if s.Around.GroupSize > 1 && !s.Around.IsGroupLeader {
		// A follower's movement belongs to its leader. Proposing travel here
		// produces a guaranteed "not_group_leader" rejection.
		return idle("bot follows a group leader")
	}

	// Rung 1: durability. A bot that cannot fight is worth fixing before it is
	// worth directing.
	if p.Th.RepairBelowDurabilityPct > 0 && s.Vit.DurabilityPct != nil &&
		*s.Vit.DurabilityPct < p.Th.RepairBelowDurabilityPct {
		if poi := p.nearest(s, "repair"); poi != nil {
			return p.travel(s, id, contract.IntentRepair, poi, 0.9, "durability below threshold")
		}
		// No repair POI in range is not a reason to do something else clever;
		// fall through and let a lower rung decide.
	}

	// Rung 2: full bags. Loot stops mattering once there is nowhere to put it.
	if s.Char.FreeBagSlots <= p.Th.VendorWhenFreeBagSlotsAtMost {
		if poi := p.nearest(s, "vendor"); poi != nil {
			return p.travel(s, id, contract.IntentVendorSell, poi, 0.8, "bags full")
		}
	}

	// Rung 3: rest. Cheap, always available, and the honest answer for a hurt
	// bot with nowhere useful to be.
	if p.Th.RestBelowHealthPct > 0 && s.Vit.HealthPct < p.Th.RestBelowHealthPct {
		in := contract.Idle(s.Bot, id, p.Name(), "health below rest threshold")
		in.Kind = contract.IntentRest
		in.Confidence = 0.7
		return in
	}

	// Rung 4: finish what is already started. A completed quest sitting in the
	// log is free progression, so turning in beats picking up.
	if poi := p.questPOI(s, "quest_turnin", statusComplete); poi != nil {
		return p.travel(s, id, contract.IntentTurnInQuest, poi, 0.85, "quest ready to hand in")
	}

	// Rung 5: make progress on an incomplete quest with a known hotspot.
	if poi := p.questPOI(s, "quest_objective", statusIncomplete); poi != nil {
		return p.travel(s, id, contract.IntentTravelTo, poi, 0.7, "quest objective outstanding")
	}

	// Rung 6: pick up new work, if the log has room to be useful. The server
	// enforces the real 1.12 quest log cap; 20 is here only so this planner does
	// not propose pickups that are certain to be refused.
	if len(s.Quests) < 20 {
		if poi := p.nearest(s, "quest_giver"); poi != nil {
			return p.travel(s, id, contract.IntentPickQuest, poi, 0.6, "quest log has room")
		}
	}

	// Rung 7: grind. The coarse "just level" answer.
	if poi := p.nearest(s, "grind_area"); poi != nil {
		return p.travel(s, id, contract.IntentGrindArea, poi, 0.5, "no quest work available")
	}

	// Rung 8: nothing to suggest. Always reachable, always valid.
	return idle("no rung matched; in-core AI continues")
}

const (
	statusComplete   = "complete"
	statusIncomplete = "incomplete"
)

// travel builds a POI-directed intent.
func (p *Planner) travel(s *contract.Snapshot, id string, kind contract.IntentKind,
	poi *contract.PointOfInterest, confidence float64, why string) contract.Intent {
	in := contract.Intent{
		Bot:        s.Bot,
		IntentID:   id,
		Kind:       kind,
		Travel:     &contract.TravelParams{POIID: poi.ID},
		Confidence: confidence,
		Source:     p.Name(),
		Rationale:  clip(why + " -> " + poi.Kind + " " + poi.ID),
	}
	if poi.RelatedQuestID != 0 &&
		(kind == contract.IntentTurnInQuest || kind == contract.IntentPickQuest) {
		in.Quest = &contract.QuestParams{QuestID: poi.RelatedQuestID}
	}
	return in
}

// nearest picks the closest POI of a kind, deterministically. Ties break on the
// POI id so that two replicas planning the same snapshot agree, which matters
// the moment this service is scaled horizontally.
func (p *Planner) nearest(s *contract.Snapshot, kind string) *contract.PointOfInterest {
	candidates := make([]*contract.PointOfInterest, 0, 4)
	for i := range s.POIs {
		poi := &s.POIs[i]
		if poi.Kind != kind || poi.ID == "" {
			continue
		}
		if !poi.Pos.SameMap(s.Pos) {
			// Cross-map candidates should have been filtered server-side. If one
			// arrives anyway, refuse it rather than compare incomparable frames.
			continue
		}
		if p.Th.MaxTravelYards > 0 && poi.DistanceYards != nil && *poi.DistanceYards > p.Th.MaxTravelYards {
			continue
		}
		candidates = append(candidates, poi)
	}
	if len(candidates) == 0 {
		return nil
	}
	sort.SliceStable(candidates, func(a, b int) bool {
		da, db := dist(candidates[a]), dist(candidates[b])
		if da != db {
			return da < db
		}
		return candidates[a].ID < candidates[b].ID
	})
	return candidates[0]
}

// questPOI finds a POI of the given kind whose related quest is in the log with
// the wanted status. Requiring the link in both directions is what stops the
// planner acting on a POI the server offered speculatively.
func (p *Planner) questPOI(s *contract.Snapshot, poiKind, wantStatus string) *contract.PointOfInterest {
	wanted := make(map[uint32]bool, len(s.Quests))
	for _, q := range s.Quests {
		if q.Status == wantStatus {
			wanted[q.QuestID] = true
		}
	}
	if len(wanted) == 0 {
		return nil
	}
	var best *contract.PointOfInterest
	for i := range s.POIs {
		poi := &s.POIs[i]
		if poi.Kind != poiKind || poi.ID == "" || !wanted[poi.RelatedQuestID] {
			continue
		}
		if !poi.Pos.SameMap(s.Pos) {
			continue
		}
		if p.Th.MaxTravelYards > 0 && poi.DistanceYards != nil && *poi.DistanceYards > p.Th.MaxTravelYards {
			continue
		}
		if best == nil || dist(poi) < dist(best) || (dist(poi) == dist(best) && poi.ID < best.ID) {
			best = poi
		}
	}
	return best
}

// dist treats an unpathed POI as very far rather than as near. Absence must
// never read as zero; that is the general rule of this contract, and it is
// load-bearing here because "distance unknown" sorting first would make the
// planner prefer exactly the destinations the server could not path to.
func dist(poi *contract.PointOfInterest) float64 {
	if poi.DistanceYards == nil {
		return 1e9
	}
	return *poi.DistanceYards
}

func clip(s string) string {
	if len(s) > contract.MaxRationaleBytes {
		return s[:contract.MaxRationaleBytes]
	}
	return s
}
