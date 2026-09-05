package contract

// BotID is the stable, permanent identity of a bot.
//
// It is the character's low GUID (characters.guid) scoped to a realm. It is the
// same value across restarts, migrations and deployments, which is what makes
// ADR-0024 invariant 1 checkable end to end: the brain can be handed a snapshot
// and asked "is this the same bot you saw yesterday" without the brain holding
// any state.
//
// The brain treats a BotID as an opaque correlation key. It may not derive an
// account, a session, a socket or a database row from it, and it may never
// suggest that one BotID be swapped for another.
type BotID struct {
	// Realm is the realm id from the logon database. Required; a snapshot
	// without it is malformed, because GUIDs are only unique within a realm.
	Realm uint32 `json:"realm"`
	// GUID is the character low GUID. Required and non-zero.
	GUID uint64 `json:"guid"`

	// UUID is the brain's stable key for this bot (ADR-0039), minted once by the
	// worldserver into cv_brain.bot_identity. It is NOT derived from Realm and
	// GUID: a realm merge shifts every guid, so a derived key would rename the
	// bot and orphan everything remembered about it, with no repair.
	//
	// Optional. Empty means the row has not been minted yet, which is a normal
	// state for a bot seen for the first time - plan for it without memory
	// rather than refusing it. Never treat empty as an error.
	//
	// This is the memory key, not the address. Intents are still addressed by
	// Realm and GUID, because those are what the applier matches on.
	UUID string `json:"uuid,omitempty"`
}

// String renders a BotID as "realm:guid" for logs and metric labels.
func (b BotID) String() string {
	return utoa(uint64(b.Realm)) + ":" + utoa(b.GUID)
}

// Position is a point on one map, in that map's local frame.
//
// There is no global coordinate frame in this game. Two positions are only
// comparable when their MapID matches; a planner that subtracts coordinates
// across maps has produced garbage, and [Position.SameMap] exists so that check
// is cheap to write.
type Position struct {
	// MapID is the mangos map id (0 Eastern Kingdoms, 1 Kalimdor, and one per
	// instance). Required.
	MapID uint32 `json:"map_id"`
	// X, Y, Z are game yards in the map-local frame.
	X float64 `json:"x"`
	Y float64 `json:"y"`
	Z float64 `json:"z"`
	// Orientation is radians in [0, 2*Pi), 0 = +X, counter-clockwise.
	// Absent (0) is indistinguishable from "facing +X", and planners must not
	// treat facing as load-bearing at this tier: by the time an intent is
	// executed the bot has turned.
	Orientation float64 `json:"orientation"`
	// ZoneID and AreaID are the client zone/area ids. Zero means the server did
	// not resolve them (it happens in transit and on some instance maps); a
	// planner must fall back to coordinates rather than assume zone 0.
	ZoneID uint32 `json:"zone_id,omitempty"`
	AreaID uint32 `json:"area_id,omitempty"`
	// InstanceID is non-zero only inside an instanced map. A bot inside an
	// instance is off limits for travel planning: the brain must not suggest a
	// destination that would require leaving.
	InstanceID uint32 `json:"instance_id,omitempty"`
}

// SameMap reports whether two positions are in a comparable frame.
func (p Position) SameMap(o Position) bool {
	return p.MapID == o.MapID && p.InstanceID == o.InstanceID
}

// Vitals is coarse condition. Deliberately percentages, not absolutes: at this
// tier the brain decides "rest or push on", never "cast this heal now".
// Absolute pools would invite tier-0 decisions to be made on data that is
// seconds stale.
type Vitals struct {
	// HealthPct in [0, 100]. Required.
	HealthPct float64 `json:"health_pct"`
	// PowerPct in [0, 100] for the class's primary power (mana, rage, energy).
	// Absent means the class has no meaningful pool to plan around.
	PowerPct *float64 `json:"power_pct,omitempty"`
	// IsDead: the bot is a corpse or a ghost. A dead bot still gets planned
	// for; resurrection and corpse runs are tier-0 concerns, so the only honest
	// intent for a dead bot is [IntentIdle].
	IsDead bool `json:"is_dead"`
	// InCombat: any intent issued for a bot in combat will almost certainly be
	// rejected by the server. It is here so planners can decline cheaply, not
	// so they can fight.
	InCombat bool `json:"in_combat"`
	// IsResting: inside a rest area (inn or city).
	IsResting bool `json:"is_resting"`
	// IsMounted affects travel-time estimates only.
	IsMounted bool `json:"is_mounted"`
	// DurabilityPct is average equipped-item durability in [0, 100]. Absent
	// means the server did not compute it this tick; a planner must not infer
	// "fine" from absence, it must simply not plan a repair trip.
	DurabilityPct *float64 `json:"durability_pct,omitempty"`
}

// Character is the slow-changing identity of the bot. All of it is derivable
// from the character row; it is sent every time because the brain is stateless
// per request (ARCH-001) and must not cache it.
type Character struct {
	// Name is the character name. Present so logs and LLM prompts are readable.
	// It is NOT an identifier: names can in principle change, BotID cannot.
	Name string `json:"name"`
	// Level in [1, 60] for 1.12.
	Level uint8 `json:"level"`
	// Class and Race are the numeric ids from the client DBCs (1 = Warrior and
	// so on). Numeric rather than strings so that a localisation or naming
	// change never becomes a contract change.
	Class uint8 `json:"class"`
	Race  uint8 `json:"race"`
	// Faction is "alliance" or "horde", derived from race server-side so the
	// brain does not have to carry a race table.
	Faction string `json:"faction"`
	// Money is total carried copper. Used for "can this bot afford repairs or a
	// mount", nothing else.
	Money uint64 `json:"money"`
	// FreeBagSlots is the count of empty inventory slots. Zero is a real value
	// (bags full) and is one of the few things worth a vendor trip for.
	FreeBagSlots uint32 `json:"free_bag_slots"`
	// TraitKeys are the deterministic personality trait keys assigned by the
	// personality layer (ARCH-002, docs/contracts/personality-context-contract-v1.md
	// section 4.1). Absent means personality is not deployed yet, which is the
	// state today; planners must behave sensibly with an empty list.
	TraitKeys []string `json:"trait_keys,omitempty"`
}

// QuestEntry is one quest in the bot's log, flattened.
//
// Quest *text* is never sent. The brain gets ids, progress and where the work
// is; the server owns the quest template. That keeps a 1000-bot batch small and
// keeps localised content out of a payload that may reach a cloud provider.
type QuestEntry struct {
	// QuestID is the quest_template entry id.
	QuestID uint32 `json:"quest_id"`
	// Status mirrors the server's quest status as a stable lowercase string:
	// "incomplete", "complete", "failed". Unknown values must be ignored by a
	// planner, not rejected: new statuses are a MINOR change.
	Status string `json:"status"`
	// ObjectivesDone and ObjectivesTotal give progress without shipping
	// objective detail. ObjectivesTotal == 0 means the quest has no counted
	// objectives (a talk-to or an escort), not that it has no work left.
	ObjectivesDone  uint32 `json:"objectives_done"`
	ObjectivesTotal uint32 `json:"objectives_total"`
	// RequiredLevel and QuestLevel let a planner rank without a quest table.
	// Zero means the server did not supply it.
	RequiredLevel uint8 `json:"required_level,omitempty"`
	QuestLevel    uint8 `json:"quest_level,omitempty"`
	// Hotspot is where the server believes the remaining work is: the objective
	// area for an incomplete quest, the turn-in NPC for a complete one. Absent
	// means the server could not resolve a location, and the planner must not
	// invent one.
	Hotspot *Position `json:"hotspot,omitempty"`
}

// PointOfInterest is a destination candidate the *server* already resolved.
//
// This is the most important shape in the snapshot. The brain never discovers
// places: it chooses among places the server has offered, because the server
// owns the world, the navmesh and what is reachable. A brain that could name
// arbitrary coordinates would be a brain that can walk bots into geometry.
type PointOfInterest struct {
	// ID is an opaque server-assigned handle, valid only for this snapshot.
	// An intent refers to a POI by this ID and the server resolves it back. If
	// the server no longer recognises the ID (the bot moved on, ticks elapsed)
	// it drops the intent. That is the designed behaviour for staleness, and it
	// is why the brain is never given raw coordinates to aim at.
	ID string `json:"id"`
	// Kind is a stable lowercase class of destination: "quest_objective",
	// "quest_turnin", "quest_giver", "vendor", "repair", "trainer",
	// "innkeeper", "mailbox", "grind_area", "flight_master", "graveyard".
	// Unknown kinds must be ignored by a planner, never rejected.
	Kind string `json:"kind"`
	// Pos is where it is. Always on the bot's current map: the server filters
	// cross-map candidates out, because cross-map travel involves flight paths
	// and is a tier-0 decision.
	Pos Position `json:"pos"`
	// DistanceYards is the server's travel estimate, which is path length where
	// the server could path it and straight-line otherwise. Absent means
	// unpathed, and the planner should treat it as expensive rather than near.
	DistanceYards *float64 `json:"distance_yards,omitempty"`
	// RelatedQuestID links a quest_* POI back to [QuestEntry.QuestID]. Zero for
	// POIs with no quest relation.
	RelatedQuestID uint32 `json:"related_quest_id,omitempty"`
	// Tags are free-form server hints ("hostile", "contested", "level_20_25").
	// Advisory only: a planner may ignore all of them and still be correct.
	Tags []string `json:"tags,omitempty"`
}

// Surroundings is an aggregate view of what is around the bot.
//
// It is counts and one or two distances, never entity lists. At 1000 bots an
// entity list per bot per tick is the payload that kills this design, and a
// planner working on seconds-old entity data would be making tier-0 decisions
// at tier-2 latency.
type Surroundings struct {
	// HostileCount, FriendlyPlayerCount and FriendlyBotCount are taken within
	// the server's aggregation radius, reported in RadiusYards.
	HostileCount        uint32 `json:"hostile_count"`
	FriendlyPlayerCount uint32 `json:"friendly_player_count"`
	FriendlyBotCount    uint32 `json:"friendly_bot_count"`
	// RadiusYards is the radius those counts were taken over. Absent means the
	// server used its default; a planner must not assume a number.
	RadiusYards *float64 `json:"radius_yards,omitempty"`
	// NearestHostileYards is absent when there is no hostile in radius. Absent
	// means "none seen", which is not the same as "zero yards away" -- hence a
	// pointer rather than a float.
	NearestHostileYards *float64 `json:"nearest_hostile_yards,omitempty"`
	// GroupSize is 1 for a solo bot. A grouped bot's travel is constrained by
	// its leader, so most travel intents for a non-leader are rejected; the
	// count is here so the planner can decline rather than be rejected.
	GroupSize uint32 `json:"group_size"`
	// IsGroupLeader is true when this bot leads its group.
	IsGroupLeader bool `json:"is_group_leader"`
}

// IntentOutcome is the server's report on the intent it was last given for this
// bot. This is how the loop is closed without the brain holding state: the
// server remembers, and the brain is told.
type IntentOutcome struct {
	// IntentID echoes [Intent.IntentID].
	IntentID string `json:"intent_id"`
	// Kind echoes [Intent.Kind].
	Kind IntentKind `json:"kind"`
	// Result is one of "accepted" (taken, still running), "completed",
	// "rejected" (validation refused it, see Reason), "failed" (started, could
	// not finish), "expired" (TTL elapsed unstarted), "superseded" (a later
	// intent replaced it). Unknown values must be ignored by a planner.
	Result string `json:"result"`
	// Reason is a short stable machine code when Result is "rejected" or
	// "failed": "unreachable", "in_combat", "not_group_leader", "stale_poi",
	// "unknown_poi", "unsupported_kind", "identity_protected". Empty otherwise.
	//
	// "identity_protected" means the server refused an intent that would have
	// touched bot identity. A brain that ever sees it has a bug; this service
	// counts it as an alert-worthy metric rather than treating it as routine.
	Reason string `json:"reason,omitempty"`
	// IssuedAtMS is when the intent was issued, server clock, Unix ms. Zero
	// means the server did not record it.
	IssuedAtMS int64 `json:"issued_at_ms,omitempty"`
}

// Snapshot is everything the brain is told about one bot.
//
// See the package doc for what is deliberately NOT here. In short: no per-tick
// combat state, no auras or cooldowns, no entity lists, no item inventories, no
// pointers or session handles, no account or player-identifying data, and no
// navmesh. Each omission is either a tier-0 concern, a bandwidth problem at
// 1000 bots, an ADR-0012 boundary rule, or an ARCH-003 egress rule.
type Snapshot struct {
	// Bot identifies which bot this is. Required.
	Bot BotID `json:"bot"`
	// Char is slow-changing character state. Required.
	Char Character `json:"char"`
	// Pos is where the bot is right now. Required.
	Pos Position `json:"pos"`
	// Vit is coarse condition. Required.
	Vit Vitals `json:"vitals"`
	// Around is the aggregate neighbourhood. Required: a bot alone in the world
	// sends zero counts, not an absent object.
	Around Surroundings `json:"surroundings"`
	// Quests is the bot's quest log. May be empty. The server caps this list.
	Quests []QuestEntry `json:"quests,omitempty"`
	// POIs are the destination candidates the server resolved for this bot. An
	// empty list is meaningful and common: it means the server found nothing
	// worth travelling to, and the only honest intent is [IntentIdle].
	POIs []PointOfInterest `json:"pois,omitempty"`
	// LastOutcome reports on the previous intent, if there was one. Absent for
	// a bot that has never been planned for, or whose history the server no
	// longer has after a restart. Absence is normal and must never be read as
	// failure.
	LastOutcome *IntentOutcome `json:"last_outcome,omitempty"`
	// ObservedAtMS is when the server sampled this bot: server clock, Unix ms.
	// It may be older than the request's own timestamp when the server batches
	// across ticks. A planner that cares about freshness compares this against
	// [PlanRequest.SentAtMS], never against its own wall clock, because the two
	// processes do not share a clock.
	ObservedAtMS int64 `json:"observed_at_ms"`
	// Hints are free-form server-side advisory strings ("low_durability",
	// "bags_full", "stuck"). Purely additive: a new hint is a MINOR change and
	// an unknown hint must be ignored.
	Hints []string `json:"hints,omitempty"`
}

// AgeMS returns how stale this snapshot was when the batch was sent. Both
// timestamps come from the server's clock, so the difference is meaningful even
// though neither is comparable to the brain's own clock. A negative result
// means the server's own numbers disagree and should be treated as unknown.
func (s *Snapshot) AgeMS(sentAtMS int64) int64 {
	if s.ObservedAtMS == 0 || sentAtMS == 0 {
		return -1
	}
	return sentAtMS - s.ObservedAtMS
}

// Validate checks the invariants a snapshot must satisfy before any planner
// touches it.
//
// It is deliberately strict about identity and lax about everything else: a
// missing optional field is the planner's problem, but a snapshot that cannot
// be attributed to a specific bot must never produce an intent, because an
// intent landing on the wrong bot is exactly the class of bug ADR-0024
// invariant 1 exists to prevent.
func (s *Snapshot) Validate() error {
	if s.Bot.GUID == 0 {
		return errMalformedf("snapshot has zero bot.guid; an unattributable snapshot cannot be planned for")
	}
	if s.Bot.Realm == 0 {
		return errMalformedf("snapshot for guid %d has zero bot.realm; GUIDs are unique only within a realm", s.Bot.GUID)
	}
	if s.Char.Level == 0 || s.Char.Level > 60 {
		return errMalformedf("bot %s has level %d, outside 1..60", s.Bot, s.Char.Level)
	}
	if s.Vit.HealthPct < 0 || s.Vit.HealthPct > 100 {
		return errMalformedf("bot %s has health_pct %v, outside 0..100", s.Bot, s.Vit.HealthPct)
	}
	return nil
}
