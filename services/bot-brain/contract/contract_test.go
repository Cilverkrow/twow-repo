package contract

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestParseVersion(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    ParsedVersion
		wantErr error
	}{
		{name: "current", in: "1.0", want: ParsedVersion{1, 0}},
		{name: "higher minor", in: "1.7", want: ParsedVersion{1, 7}},
		{name: "future major", in: "2.0", want: ParsedVersion{2, 0}},
		{name: "empty is refused, never defaulted", in: "", wantErr: ErrVersionSkew},
		{name: "no minor", in: "1", wantErr: ErrVersionSkew},
		{name: "three parts", in: "1.0.0", wantErr: ErrVersionSkew},
		{name: "non numeric major", in: "x.0", wantErr: ErrVersionSkew},
		{name: "non numeric minor", in: "1.x", wantErr: ErrVersionSkew},
		{name: "negative", in: "-1.0", wantErr: ErrVersionSkew},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseVersion(tc.in)
			if tc.wantErr != nil {
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("ParseVersion(%q) error = %v, want %v", tc.in, err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseVersion(%q) unexpected error: %v", tc.in, err)
			}
			if got != tc.want {
				t.Fatalf("ParseVersion(%q) = %v, want %v", tc.in, got, tc.want)
			}
		})
	}
}

func TestNegotiate(t *testing.T) {
	tests := []struct {
		name      string
		peer      string
		want      string
		wantSkew  bool
		reasoning string
	}{
		{
			name: "exact match", peer: "1.0", want: "1.0",
			reasoning: "the happy path",
		},
		{
			name: "peer is newer minor", peer: "1.9", want: "1.0",
			reasoning: "C++ deployed ahead of the service: serve it, stamped with what we actually speak",
		},
		{
			name: "peer is older minor", peer: "1.0", want: "1.0",
			reasoning: "service ahead of C++: stamp down so the peer is not told about fields it predates",
		},
		{
			name: "different major", peer: "2.0", wantSkew: true,
			reasoning: "fields may be repurposed; serving would be wrong behaviour rather than an error",
		},
		{
			name: "major zero", peer: "0.9", wantSkew: true,
		},
		{
			name: "missing version", peer: "", wantSkew: true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Negotiate(tc.peer)
			if tc.wantSkew {
				if !errors.Is(err, ErrVersionSkew) {
					t.Fatalf("Negotiate(%q) error = %v, want ErrVersionSkew (%s)", tc.peer, err, tc.reasoning)
				}
				return
			}
			if err != nil {
				t.Fatalf("Negotiate(%q) unexpected error: %v", tc.peer, err)
			}
			if got.String() != tc.want {
				t.Fatalf("Negotiate(%q) = %s, want %s (%s)", tc.peer, got, tc.want, tc.reasoning)
			}
		})
	}
}

// A newer peer sending fields this build has never heard of must still be
// served. This is the direction of skew that a rolling deployment produces, and
// rejecting it would turn every deploy into an outage.
func TestDecodeToleratesUnknownFields(t *testing.T) {
	body := `{
	  "contract_version": "1.4",
	  "request_id": "r1",
	  "sent_at_ms": 1700000000000,
	  "deadline_ms": 500,
	  "telemetry_budget": {"cpu": 3},
	  "snapshots": [{
	    "bot": {"realm": 1, "guid": 42},
	    "char": {"name": "Bot", "level": 10, "class": 1, "race": 1, "faction": "alliance"},
	    "pos": {"map_id": 0, "x": 1, "y": 2, "z": 3},
	    "vitals": {"health_pct": 100},
	    "surroundings": {"group_size": 1},
	    "observed_at_ms": 1699999999000,
	    "mood": "curious",
	    "aura_ids": [1,2,3]
	  }]
	}`
	req, res, err := DecodePlanRequest(strings.NewReader(body), 0)
	if err != nil {
		t.Fatalf("decode failed on a newer peer's request: %v", err)
	}
	if res.Effective.String() != "1.0" {
		t.Fatalf("effective version = %s, want 1.0", res.Effective)
	}
	if res.UnknownFields != 3 {
		t.Fatalf("UnknownFields = %d, want 3 (telemetry_budget, mood, aura_ids); saw %v",
			res.UnknownFields, res.UnknownFieldNames)
	}
	if len(req.Snapshots) != 1 || req.Snapshots[0].Bot.GUID != 42 {
		t.Fatalf("known fields were not decoded: %+v", req.Snapshots)
	}
	if req.Snapshots[0].Char.Level != 10 {
		t.Fatalf("level = %d, want 10", req.Snapshots[0].Char.Level)
	}
}

func TestDecodePlanRequestErrors(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		maxBatch int
		wantErr  error
	}{
		{
			name:    "major skew refused before anything else is read",
			body:    `{"contract_version":"2.0","snapshots":[]}`,
			wantErr: ErrVersionSkew,
		},
		{
			name:    "missing version",
			body:    `{"snapshots":[{"bot":{"realm":1,"guid":1}}]}`,
			wantErr: ErrVersionSkew,
		},
		{
			name:    "version wrong type",
			body:    `{"contract_version":1,"snapshots":[]}`,
			wantErr: ErrMalformed,
		},
		{
			name:    "not an object",
			body:    `[1,2,3]`,
			wantErr: ErrMalformed,
		},
		{
			name:    "empty batch",
			body:    `{"contract_version":"1.0","snapshots":[]}`,
			wantErr: ErrMalformed,
		},
		{
			name:    "structural mismatch",
			body:    `{"contract_version":"1.0","snapshots":"lots"}`,
			wantErr: ErrMalformed,
		},
		{
			name:     "batch too large",
			body:     `{"contract_version":"1.0","snapshots":[{},{},{}]}`,
			maxBatch: 2,
			wantErr:  ErrBatchTooLarge,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := DecodePlanRequest(strings.NewReader(tc.body), tc.maxBatch)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
		})
	}
}

func TestSnapshotValidate(t *testing.T) {
	valid := func() Snapshot {
		return Snapshot{
			Bot:  BotID{Realm: 1, GUID: 7},
			Char: Character{Level: 30},
			Vit:  Vitals{HealthPct: 80},
		}
	}
	tests := []struct {
		name    string
		mutate  func(*Snapshot)
		wantErr bool
	}{
		{name: "valid", mutate: func(*Snapshot) {}},
		{name: "zero guid is unattributable", mutate: func(s *Snapshot) { s.Bot.GUID = 0 }, wantErr: true},
		{name: "zero realm makes the guid ambiguous", mutate: func(s *Snapshot) { s.Bot.Realm = 0 }, wantErr: true},
		{name: "level zero", mutate: func(s *Snapshot) { s.Char.Level = 0 }, wantErr: true},
		{name: "level above 60", mutate: func(s *Snapshot) { s.Char.Level = 61 }, wantErr: true},
		{name: "health above 100", mutate: func(s *Snapshot) { s.Vit.HealthPct = 101 }, wantErr: true},
		{name: "negative health", mutate: func(s *Snapshot) { s.Vit.HealthPct = -1 }, wantErr: true},
		{name: "health zero is legal", mutate: func(s *Snapshot) { s.Vit.HealthPct = 0 }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := valid()
			tc.mutate(&s)
			err := s.Validate()
			if tc.wantErr != (err != nil) {
				t.Fatalf("Validate() err = %v, wantErr = %v", err, tc.wantErr)
			}
		})
	}
}

func TestIntentValidate(t *testing.T) {
	bot := BotID{Realm: 1, GUID: 9}
	tests := []struct {
		name    string
		in      Intent
		wantErr bool
	}{
		{
			name: "idle needs no params",
			in:   Idle(bot, "i1", "rule", "nothing to do"),
		},
		{
			name:    "travel needs a poi",
			in:      Intent{Bot: bot, IntentID: "i1", Kind: IntentTravelTo},
			wantErr: true,
		},
		{
			name: "travel with a poi",
			in:   Intent{Bot: bot, IntentID: "i1", Kind: IntentTravelTo, Travel: &TravelParams{POIID: "p1"}},
		},
		{
			name:    "abandon needs a quest",
			in:      Intent{Bot: bot, IntentID: "i1", Kind: IntentAbandonQuest},
			wantErr: true,
		},
		{
			name: "abandon with a quest",
			in:   Intent{Bot: bot, IntentID: "i1", Kind: IntentAbandonQuest, Quest: &QuestParams{QuestID: 5}},
		},
		{
			name:    "unknown kind",
			in:      Intent{Bot: bot, IntentID: "i1", Kind: IntentKind("delete_bot")},
			wantErr: true,
		},
		{
			name:    "no identity",
			in:      Intent{IntentID: "i1", Kind: IntentIdle},
			wantErr: true,
		},
		{
			name:    "no intent id",
			in:      Intent{Bot: bot, Kind: IntentIdle},
			wantErr: true,
		},
		{
			name:    "confidence out of range",
			in:      Intent{Bot: bot, IntentID: "i1", Kind: IntentIdle, Confidence: 1.5},
			wantErr: true,
		},
		{
			name: "oversized rationale",
			in: Intent{Bot: bot, IntentID: "i1", Kind: IntentIdle,
				Rationale: strings.Repeat("x", MaxRationaleBytes+1)},
			wantErr: true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.in.Validate()
			if tc.wantErr != (err != nil) {
				t.Fatalf("Validate() err = %v, wantErr = %v", err, tc.wantErr)
			}
		})
	}
}

// ADR-0024 invariant 1 is enforced by vocabulary: there must be no intent kind
// that can lose or replace a bot. This test fails the moment somebody adds one.
func TestNoIntentKindTouchesIdentity(t *testing.T) {
	forbidden := []string{"delete", "remove", "replace", "reroll", "re_roll",
		"logout", "log_out", "teleport", "relocate", "substitute", "recreate", "swap"}
	for _, k := range KnownIntentKinds {
		lower := strings.ToLower(string(k))
		for _, bad := range forbidden {
			if strings.Contains(lower, bad) {
				t.Fatalf("intent kind %q looks like it touches bot identity or placement; "+
					"ADR-0024 invariant 1 forbids the brain having that vocabulary", k)
			}
		}
	}
}

// Absence must survive a JSON round trip distinct from zero. Several planner
// decisions turn on "the server did not tell us" versus "the server told us
// zero", and collapsing the two silently produces confidently wrong plans.
func TestOptionalScalarsDistinguishAbsentFromZero(t *testing.T) {
	zero := 0.0
	withZero := Snapshot{Vit: Vitals{DurabilityPct: &zero}}
	absent := Snapshot{}

	encZero, err := json.Marshal(withZero)
	if err != nil {
		t.Fatal(err)
	}
	encAbsent, err := json.Marshal(absent)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encZero), `"durability_pct":0`) {
		t.Fatalf("an explicit zero durability was not encoded: %s", encZero)
	}
	if strings.Contains(string(encAbsent), "durability_pct") {
		t.Fatalf("an absent durability was encoded anyway: %s", encAbsent)
	}

	var back Snapshot
	if err := json.Unmarshal(encZero, &back); err != nil {
		t.Fatal(err)
	}
	if back.Vit.DurabilityPct == nil || *back.Vit.DurabilityPct != 0 {
		t.Fatalf("explicit zero did not survive the round trip: %v", back.Vit.DurabilityPct)
	}
	var backAbsent Snapshot
	if err := json.Unmarshal(encAbsent, &backAbsent); err != nil {
		t.Fatal(err)
	}
	if backAbsent.Vit.DurabilityPct != nil {
		t.Fatalf("absence decoded as present")
	}
}

func TestPositionSameMap(t *testing.T) {
	a := Position{MapID: 0}
	tests := []struct {
		name string
		b    Position
		want bool
	}{
		{name: "same map", b: Position{MapID: 0}, want: true},
		{name: "different map", b: Position{MapID: 1}},
		{name: "same map different instance", b: Position{MapID: 0, InstanceID: 3}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := a.SameMap(tc.b); got != tc.want {
				t.Fatalf("SameMap = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestSnapshotAgeMS(t *testing.T) {
	s := Snapshot{ObservedAtMS: 1000}
	if got := s.AgeMS(1500); got != 500 {
		t.Fatalf("AgeMS = %d, want 500", got)
	}
	if got := s.AgeMS(0); got != -1 {
		t.Fatalf("AgeMS with no server clock = %d, want -1 (unknown)", got)
	}
	empty := Snapshot{}
	if got := empty.AgeMS(1500); got != -1 {
		t.Fatalf("AgeMS with no observation time = %d, want -1 (unknown)", got)
	}
}

func TestInfoAdvertisesEverythingSkewDetectionNeeds(t *testing.T) {
	info := Info(512)
	if info.Version != Version {
		t.Fatalf("version = %q, want %q", info.Version, Version)
	}
	if len(info.SupportedMajors) == 0 {
		t.Fatal("no supported majors advertised; the C++ side cannot detect skew at startup")
	}
	if len(info.KnownIntentKinds) != len(KnownIntentKinds) {
		t.Fatalf("kinds = %d, want %d", len(info.KnownIntentKinds), len(KnownIntentKinds))
	}
	if info.MaxBatch != 512 {
		t.Fatalf("max batch = %d, want 512", info.MaxBatch)
	}
}
