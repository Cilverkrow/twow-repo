package contract

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// The wire name and the round trip.
//
// This is the test that would have caught the failure the golden fixtures exist
// for: a field renamed on one side. The C++ decoder looks for "command" and for
// these five spellings, so a rename here is a bot that silently never obeys.
func TestDialogueCommandRoundTripsTheWire(t *testing.T) {
	for _, cmd := range KnownDialogueCommands {
		t.Run(string(cmd), func(t *testing.T) {
			raw, err := json.Marshal(DialogueResponse{
				Bot: BotID{Realm: 1, GUID: 42}, Spoke: true, Reply: "Ich komme.", Command: cmd,
			})
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(raw), `"command":"`+string(cmd)+`"`) {
				t.Fatalf("command %q did not encode under the name the C++ side reads: %s", cmd, raw)
			}
			var back DialogueResponse
			if err := json.Unmarshal(raw, &back); err != nil {
				t.Fatal(err)
			}
			if back.Command != cmd {
				t.Fatalf("round trip = %q, want %q", back.Command, cmd)
			}
			if err := back.Validate(); err != nil {
				t.Fatalf("a known command failed validation: %v", err)
			}
		})
	}
}

// The five spellings, asserted literally.
//
// KnownDialogueCommands is a list this file could have derived from the
// constants, which would prove nothing. These are the strings BotDialogueCommand
// on the C++ side switches on, written out, so that changing one is a visible
// diff in a test rather than a silent behaviour change.
func TestDialogueCommandNamesAreTheOnesTheWorldserverKnows(t *testing.T) {
	want := []string{"follow", "stay", "flee", "attack", "equip_upgrades"}
	if len(KnownDialogueCommands) != len(want) {
		t.Fatalf("the command set has changed size: %v", KnownDialogueCommands)
	}
	for i, name := range want {
		if string(KnownDialogueCommands[i]) != name {
			t.Fatalf("command %d = %q, want %q", i, KnownDialogueCommands[i], name)
		}
	}
	if CommandNone != "" {
		t.Fatalf("CommandNone must be the empty string so it omits from the wire, got %q", CommandNone)
	}
	if CommandNone.IsKnown() {
		t.Fatal("CommandNone must not report itself as a known command")
	}
}

// A command nobody can execute must not reach a worldserver.
func TestDialogueResponseRefusesAnUnknownCommand(t *testing.T) {
	tests := []struct {
		name     string
		command  DialogueCommand
		prevents string
	}{{
		name:     "a command this build never defined",
		command:  DialogueCommand("summon"),
		prevents: "a service that learned a command before the worldserver did asking for it anyway",
	}, {
		name:     "a case variant of a real one",
		command:  DialogueCommand("Follow"),
		prevents: "a near-miss being treated as the command it resembles",
	}, {
		name:     "a command with an argument smuggled into it",
		command:  DialogueCommand("attack Thrainn"),
		prevents: "the enum being used as a free-text field",
	}}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			resp := DialogueResponse{Bot: BotID{Realm: 1, GUID: 42}, Spoke: true, Reply: "Ja.", Command: tc.command}
			err := resp.Validate()
			if err == nil {
				t.Fatalf("an unknown command validated; prevents: %s", tc.prevents)
			}
			if !errors.Is(err, ErrMalformed) {
				t.Fatalf("err = %v, want ErrMalformed", err)
			}
		})
	}
}

// Acting without speaking is a normal outcome, not a malformed response.
//
// "Komm her" deserves obedience more than it deserves a sentence, and section
// 11.7 is explicit that not every line deserves a reply. A validator that
// insisted on a reply here would make the useful case the illegal one.
func TestDialogueSilentResponseMayStillCarryACommand(t *testing.T) {
	resp := DialogueResponse{
		Bot: BotID{Realm: 1, GUID: 42}, Spoke: false,
		Reason: SilenceNothingToSay, Command: CommandFollow,
	}
	if err := resp.Validate(); err != nil {
		t.Fatalf("a silent response carrying a command was refused: %v", err)
	}

	// ... but a silent one still needs its reason, command or no command:
	// otherwise there is one silence an operator cannot explain.
	resp.Reason = ""
	if err := resp.Validate(); err == nil {
		t.Fatal("a silent response with a command but no reason validated")
	}

	// And an unknown command is refused even on a silent response, because that
	// is the half that would have done something.
	resp.Reason = SilenceNothingToSay
	resp.Command = DialogueCommand("logout")
	if err := resp.Validate(); err == nil {
		t.Fatal("a silent response carrying an unknown command validated")
	}
}

// No command at all is the default, and it must not appear on the wire.
func TestDialogueResponseOmitsAnAbsentCommand(t *testing.T) {
	raw, err := json.Marshal(DialogueResponse{Bot: BotID{Realm: 1, GUID: 42}, Spoke: true, Reply: "Hallo."})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "command") {
		t.Fatalf("an absent command was encoded: %s", raw)
	}
}

// allow_commands is a field this build knows, so it must not be counted as one
// a peer sent that we ignore. That counter is the rolling-deployment signal; a
// field we added and forgot to declare would make it lie.
func TestDialogueRequestKnowsAllowCommands(t *testing.T) {
	body := `{"contract_version":"1.5","bot":{"realm":1,"guid":42},"channel":"party",` +
		`"speaker":"player","message":"Komm her","allow_commands":true}`
	req, res, err := DecodeDialogueRequest(strings.NewReader(body))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !req.AllowCommands {
		t.Fatal("allow_commands did not decode")
	}
	if res.UnknownFields != 0 {
		t.Fatalf("UnknownFields = %d, want 0; saw %v", res.UnknownFields, res.UnknownFieldNames)
	}

	// Absent means text only, and the zero value is the safe one.
	req, _, err = DecodeDialogueRequest(strings.NewReader(strings.Replace(body, `,"allow_commands":true`, "", 1)))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if req.AllowCommands {
		t.Fatal("a request that said nothing about commands defaulted to allowing them")
	}
}
