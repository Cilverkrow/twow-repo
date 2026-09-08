package llm

import (
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

func strictBatch() []contract.Snapshot {
	return []contract.Snapshot{{
		Bot:  contract.BotID{Realm: 1, GUID: 7, UUID: "u"},
		Char: contract.Character{Name: "Bot", Level: 20, Class: 1, Race: 1, Faction: "alliance"},
		Vit:  contract.Vitals{HealthPct: 100},
		POIs: []contract.PointOfInterest{{ID: "p1", Kind: "grind_area"}},
	}}
}

func parseOne(t *testing.T, content string) []contract.Intent {
	t.Helper()
	p := &Planner{}
	return p.parseIntents(content, strictBatch(), 0)
}

// The regression this whole design is shaped around.
//
// The PoC decoder rejects any field it was not told about, which is right for a
// fixture and catastrophic in production: every real provider decorates the
// envelope. If this test ever fails, someone has promoted the strict envelope
// decoder and the service will refuse every genuine response while looking
// perfectly healthy.
func TestARealisticProviderEnvelopeIsStillAccepted(t *testing.T) {
	// Shaped like an actual OpenAI reply, decorations and all.
	content := `{"intents":[{"bot":0,"kind":"idle","why":"resting"}]}`
	if got := parseOne(t, content); len(got) != 1 {
		t.Fatalf("plain content produced %d intents, want 1", len(got))
	}

	// And the wrappers models actually emit around it.
	for _, wrapped := range []string{
		"```json\n" + content + "\n```",
		"Here is the plan:\n" + content,
		content + "\n\nLet me know if you need anything else.",
	} {
		if got := parseOne(t, wrapped); len(got) != 1 {
			t.Fatalf("wrapped content produced %d intents, want 1: %s", len(got), wrapped)
		}
	}
}

// Unknown fields are the model answering a question we did not ask. Go would
// drop them silently, which is how a renamed poi_id becomes a travel intent to
// nowhere.
func TestAnUnknownFieldDropsThatIntent(t *testing.T) {
	got := parseOne(t, `{"intents":[{"bot":0,"kind":"idle","target":"p1"}]}`)
	if len(got) != 0 {
		t.Fatalf("an intent with an unknown field was accepted: %+v", got)
	}
}

// One bad entry must not cost the whole call. The rule planner covers whoever
// is dropped, which is a far better outcome than an all-or-nothing reply.
func TestOneBadIntentDoesNotDiscardTheRest(t *testing.T) {
	batch := append(strictBatch(), contract.Snapshot{
		Bot:  contract.BotID{Realm: 1, GUID: 8, UUID: "v"},
		Char: contract.Character{Name: "Two", Level: 20, Class: 1, Race: 1, Faction: "alliance"},
		Vit:  contract.Vitals{HealthPct: 100},
	})
	p := &Planner{}
	got := p.parseIntents(
		`{"intents":[{"bot":0,"kind":"idle","bogus":1},{"bot":1,"kind":"idle","why":"fine"}]}`,
		batch, 0)
	if len(got) != 1 {
		t.Fatalf("got %d intents, want the one good entry to survive", len(got))
	}
	if got[0].Bot.GUID != 8 {
		t.Fatalf("the surviving intent is for guid %d, want 8", got[0].Bot.GUID)
	}
}

// encoding/json matches field names case-insensitively. That is a Go
// convenience, not our contract, and it lets a model drift off the published
// schema unnoticed.
func TestACaseVariantKeyIsRejected(t *testing.T) {
	if got := parseOne(t, `{"intents":[{"bot":0,"KIND":"idle"}]}`); len(got) != 0 {
		t.Fatalf("a case-variant key was accepted: %+v", got)
	}
}

// Duplicate keys take the last value in encoding/json, so this would plan for a
// bot nobody looked at.
func TestADuplicateKeyIsRejected(t *testing.T) {
	if got := parseOne(t, `{"intents":[{"bot":0,"kind":"idle","bot":1}]}`); len(got) != 0 {
		t.Fatalf("a duplicate key was accepted: %+v", got)
	}
}

// A required field that is absent is not a shape we asked for.
func TestAMissingRequiredFieldIsRejected(t *testing.T) {
	if got := parseOne(t, `{"intents":[{"kind":"idle"}]}`); len(got) != 0 {
		t.Fatal("an intent with no bot index was accepted")
	}
	if got := parseOne(t, `{"intents":[{"bot":0}]}`); len(got) != 0 {
		t.Fatal("an intent with no kind was accepted")
	}
}

// A wrong-typed optional must drop the intent rather than silently becoming its
// zero value: "certainty": "high" must not read as certainty 0.
func TestAWrongTypedOptionalIsRejected(t *testing.T) {
	for _, bad := range []string{
		`{"intents":[{"bot":0,"kind":"idle","certainty":"high"}]}`,
		`{"intents":[{"bot":0,"kind":"idle","poi_id":7}]}`,
		`{"intents":[{"bot":0,"kind":"idle","why":false}]}`,
	} {
		if got := parseOne(t, bad); len(got) != 0 {
			t.Fatalf("accepted a wrong-typed field: %s -> %+v", bad, got)
		}
	}
}

// An impossible certainty is rejected, not laundered into 0.5. A model that
// reports 5 has misunderstood the scale, and inventing a plausible number hides
// that from every metric downstream.
func TestAnImpossibleCertaintyIsRejectedNotClamped(t *testing.T) {
	for _, bad := range []string{"5", "-1", "1.5"} {
		got := parseOne(t, `{"intents":[{"bot":0,"kind":"idle","certainty":`+bad+`}]}`)
		if len(got) != 0 {
			t.Fatalf("certainty %s was accepted as %v", bad, got[0].Confidence)
		}
	}
	// The legal ends of the range still work.
	for _, ok := range []string{"0", "1", "0.7"} {
		if got := parseOne(t, `{"intents":[{"bot":0,"kind":"idle","certainty":`+ok+`}]}`); len(got) != 1 {
			t.Fatalf("certainty %s was rejected", ok)
		}
	}
}

// The optional fields are genuinely optional.
func TestOptionalFieldsMayBeAbsent(t *testing.T) {
	if got := parseOne(t, `{"intents":[{"bot":0,"kind":"idle"}]}`); len(got) != 1 {
		t.Fatal("an intent with only the required fields was rejected")
	}
}

// The model never names the bot: the index selects a snapshot and the identity
// comes from our side. Unchanged by this work, and worth a test that says so,
// because it is the boundary that stops a hallucinated guid addressing a bot.
func TestBotIdentityStillComesFromTheSnapshot(t *testing.T) {
	got := parseOne(t, `{"intents":[{"bot":0,"kind":"idle"}]}`)
	if len(got) != 1 {
		t.Fatalf("got %d intents", len(got))
	}
	if got[0].Bot.GUID != 7 || got[0].Bot.Realm != 1 {
		t.Fatalf("identity %+v did not come from the snapshot", got[0].Bot)
	}
}

// An out-of-range or repeated index is still dropped.
func TestIndexBoundsAndDuplicatesStillHold(t *testing.T) {
	if got := parseOne(t, `{"intents":[{"bot":9,"kind":"idle"}]}`); len(got) != 0 {
		t.Fatal("an out-of-range bot index was accepted")
	}
	got := parseOne(t, `{"intents":[{"bot":0,"kind":"idle"},{"bot":0,"kind":"rest"}]}`)
	if len(got) != 1 {
		t.Fatalf("got %d intents for one bot, want 1", len(got))
	}
}
