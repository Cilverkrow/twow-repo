package contract

// The Go half of the cross-language contract check.
//
// This file decodes contracts/bot-brain/v1/golden/plan-request.json - the shape
// modules/mod-bot-brain's EncodePlanRequest produces - and asserts what came
// out. The C++ half does the mirror image in
// modules/mod-bot-brain/t/bot_brain_wire_tests.cpp, decoding the response and
// contract-info fixtures this side writes.
//
// Each side checks the fixture it must READ. A side checking its own output
// against a golden would only prove it agrees with itself, which is exactly the
// failure these files exist to catch: the wire format is defined twice, by
// hand, in two languages, and until this test nothing compared them.
//
// See contracts/bot-brain/v1/README.md. If a change here needs the fixture
// edited, that is a wire-format change and both version declarations move with
// it.

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

const goldenDir = "../../../contracts/bot-brain/v1/golden"

func readGolden(t *testing.T, name string) []byte {
	t.Helper()
	p := filepath.Join(goldenDir, name)
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("reading golden fixture %s: %v", p, err)
	}
	return b
}

// Strict: an unknown key means the fixture and the Go type have drifted, which
// is the whole thing being tested. json.Unmarshal would silently ignore it.
func decodeStrict(b []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// The whole point: what the C++ encoder writes, this decoder accepts, with the
// values intact.
func TestGoldenPlanRequestDecodes(t *testing.T) {
	body := readGolden(t, "plan-request.json")

	req, res, err := DecodePlanRequest(bytes.NewReader(body), 2048)
	if err != nil {
		t.Fatalf("the golden request must decode, got: %v", err)
	}

	// Unknown fields are how skew announces itself. A fixture that trips this
	// means one side grew a field the other has never heard of.
	if res.UnknownFields != 0 {
		t.Errorf("golden request carries %d unknown field(s): %v",
			res.UnknownFields, res.UnknownFieldNames)
	}
	if res.Effective.Major != VersionMajor {
		t.Errorf("negotiated major = %d, want %d", res.Effective.Major, VersionMajor)
	}
	if len(req.Snapshots) != 1 {
		t.Fatalf("snapshots = %d, want 1", len(req.Snapshots))
	}

	s := req.Snapshots[0]

	if s.Bot.Realm != 1 || s.Bot.GUID != 4242 {
		t.Errorf("bot = %+v, want realm 1 guid 4242", s.Bot)
	}
	if s.Char.Name != "Goldenbot" || s.Char.Level != 23 {
		t.Errorf("char = %q level %d, want Goldenbot 23", s.Char.Name, s.Char.Level)
	}
	if s.Char.FreeBagSlots != 3 {
		t.Errorf("free_bag_slots = %d, want 3", s.Char.FreeBagSlots)
	}

	// Percentages are 0..100, never 0..1. Getting this wrong on one side turns
	// a healthy bot into one that looks nearly dead, and every rung of the rule
	// ladder reads it.
	if s.Vit.HealthPct != 61.5 {
		t.Errorf("health_pct = %v, want 61.5 (0..100 scale)", s.Vit.HealthPct)
	}

	// durability_pct is nested under vitals, not under char, and it is optional
	// because "no item has durability" must stay distinguishable from "every
	// item is broken".
	if s.Vit.DurabilityPct == nil {
		t.Fatal("durability_pct absent; the fixture sets it, so either the key moved or optionality broke")
	}
	if *s.Vit.DurabilityPct != 88.25 {
		t.Errorf("durability_pct = %v, want 88.25", *s.Vit.DurabilityPct)
	}
	if s.Vit.PowerPct == nil || *s.Vit.PowerPct != 42 {
		t.Errorf("power_pct = %v, want 42", s.Vit.PowerPct)
	}

	// "pois", not "poi". BotBrainWire.cpp:242 carries a comment about this
	// because it has been got wrong before; a misspelling here decodes to an
	// empty slice and every bot receives no intent, silently.
	if len(s.POIs) != 2 {
		t.Fatalf("pois = %d, want 2 (a wrong key name decodes as empty, not as an error)", len(s.POIs))
	}
	if s.POIs[0].ID != "p0" || s.POIs[0].Kind != "quest_objective" {
		t.Errorf("pois[0] = %+v, want id p0 kind quest_objective", s.POIs[0])
	}
	if s.POIs[0].DistanceYards == nil || *s.POIs[0].DistanceYards != 112.5 {
		t.Errorf("pois[0].distance_yards = %v, want 112.5", s.POIs[0].DistanceYards)
	}
	if s.POIs[0].RelatedQuestID != 788 {
		t.Errorf("pois[0].related_quest_id = %d, want 788", s.POIs[0].RelatedQuestID)
	}
	// The second POI omits distance_yards' siblings deliberately: absent must
	// decode as absent, not as zero.
	if s.POIs[1].RelatedQuestID != 0 {
		t.Errorf("pois[1].related_quest_id = %d, want 0 (absent)", s.POIs[1].RelatedQuestID)
	}

	if len(s.Quests) != 1 || s.Quests[0].QuestID != 788 {
		t.Fatalf("quests = %+v, want one entry for 788", s.Quests)
	}
	if s.Quests[0].ObjectivesDone != 1 || s.Quests[0].ObjectivesTotal != 3 {
		t.Errorf("objectives = %d/%d, want 1/3",
			s.Quests[0].ObjectivesDone, s.Quests[0].ObjectivesTotal)
	}

	// last_outcome is the feedback channel. The fixture carries a REJECTION on
	// purpose: the C++ side currently only ever records "accepted", and a
	// planner that consumes outcomes has to handle the other case. If this
	// stops decoding, the loop is broken before anyone writes the planner half.
	if s.LastOutcome == nil {
		t.Fatal("last_outcome absent; the feedback channel is how a bot stops retrying an unreachable POI")
	}
	if s.LastOutcome.Result != "rejected" || s.LastOutcome.Reason != "unreachable" {
		t.Errorf("last_outcome = %+v, want rejected/unreachable", *s.LastOutcome)
	}

	if s.ObservedAtMS != 1756700000000 {
		t.Errorf("observed_at_ms = %d, want 1756700000000", s.ObservedAtMS)
	}

	// Whatever the fixture says, it must satisfy the same validation a live
	// snapshot does - otherwise it is testing a shape the service would reject.
	if err := s.Validate(); err != nil {
		t.Errorf("the golden snapshot must pass Validate(), got: %v", err)
	}
}

// The response and contract-info fixtures are read by C++, but they must also
// be what this side actually produces. Marshalling the Go types and decoding
// the fixture into them catches a tag rename here that the C++ test would
// otherwise report as "the service sent something wrong".
func TestGoldenResponseAndContractInfoMatchGoTypes(t *testing.T) {
	t.Run("plan-response", func(t *testing.T) {
		var resp PlanResponse
		if err := decodeStrict(readGolden(t, "plan-response.json"), &resp); err != nil {
			t.Fatalf("plan-response.json does not fit PlanResponse: %v", err)
		}
		if resp.ContractVersion != Version {
			t.Errorf("contract_version = %q, want %q", resp.ContractVersion, Version)
		}
		if len(resp.Intents) != 2 {
			t.Fatalf("intents = %d, want 2", len(resp.Intents))
		}
		first := resp.Intents[0]
		if first.Kind != IntentTravelTo {
			t.Errorf("intents[0].kind = %q, want %q", first.Kind, IntentTravelTo)
		}
		if first.Travel == nil || first.Travel.POIID != "p0" {
			t.Fatalf("intents[0].travel = %+v, want poi_id p0", first.Travel)
		}
		if err := first.Validate(); err != nil {
			t.Errorf("intents[0] must pass Validate(), got: %v", err)
		}
		// An error entry alongside intents is normal: a per-bot failure never
		// fails the batch.
		if len(resp.Errors) != 1 || resp.Errors[0].Code != CodeBotUnplannable {
			t.Errorf("errors = %+v, want one %s", resp.Errors, CodeBotUnplannable)
		}
		if resp.Stats.SnapshotsIn != 3 || resp.Stats.IntentsOut != 2 {
			t.Errorf("stats = %+v, want snapshots_in 3 intents_out 2", resp.Stats)
		}
	})

	t.Run("contract-info", func(t *testing.T) {
		var info ContractInfo
		if err := decodeStrict(readGolden(t, "contract-info.json"), &info); err != nil {
			t.Fatalf("contract-info.json does not fit ContractInfo: %v", err)
		}
		if info.Version != Version {
			t.Errorf("version = %q, want %q", info.Version, Version)
		}
		// The handshake is fail-closed on major skew, so this list is what a
		// peer checks itself against.
		if len(info.SupportedMajors) != 1 || info.SupportedMajors[0] != VersionMajor {
			t.Errorf("supported_majors = %v, want [%d]", info.SupportedMajors, VersionMajor)
		}
		// Every kind the vocabulary knows must be advertised, or a peer will
		// treat a legitimate intent as unknown and drop it.
		if len(info.KnownIntentKinds) != len(KnownIntentKinds) {
			t.Errorf("known_intent_kinds has %d entries, want %d - the fixture and the vocabulary have drifted",
				len(info.KnownIntentKinds), len(KnownIntentKinds))
		}
		for _, k := range info.KnownIntentKinds {
			if !k.IsKnown() {
				t.Errorf("fixture advertises %q, which IsKnown() rejects", k)
			}
		}
	})
}
