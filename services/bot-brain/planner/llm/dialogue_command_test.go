package llm

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

// With commands off, the model is never told there is a lever.
//
// This is the cheapest half of the defence and the one worth asserting: a
// message trying to talk a bot into following cannot reach a vocabulary that is
// not in the prompt. The expensive half -- HandleCommand refusing a speaker
// without standing -- lives in the worldserver and cannot be tested from here.
func TestDialoguePromptOffersCommandsOnlyWhenAllowed(t *testing.T) {
	var sent string
	d := dialogueWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		sent = string(raw)
		_, _ = w.Write([]byte(replyEnvelope(`{"reply":"Ja."}`)))
	})

	req := dialogueFixture()
	if _, err := d.Speak(context.Background(), req); err != nil {
		t.Fatalf("speak: %v", err)
	}
	for _, forbidden := range []string{"equip_upgrades", `"command"`, "follow"} {
		if strings.Contains(sent, forbidden) {
			t.Fatalf("a text-only request had %q in its prompt: %s", forbidden, sent)
		}
	}

	req.AllowCommands = true
	if _, err := d.Speak(context.Background(), req); err != nil {
		t.Fatalf("speak: %v", err)
	}
	for _, want := range []string{"equip_upgrades", `command`, "follow", "stay", "flee", "attack"} {
		if !strings.Contains(sent, want) {
			t.Fatalf("a command-enabled request did not mention %q: %s", want, sent)
		}
	}
}

func TestDialogueCommandDecoding(t *testing.T) {
	tests := []struct {
		name        string
		allow       bool
		content     string
		wantCommand contract.DialogueCommand
		wantSpoke   bool
		wantReason  string
		prevents    string
	}{{
		name:        "a reply and a command together",
		allow:       true,
		content:     `{"reply":"Ich komme.","command":"follow"}`,
		wantCommand: contract.CommandFollow,
		wantSpoke:   true,
		prevents:    "the ordinary case breaking without any other case noticing",
	}, {
		name:        "a command with no reply is silence that still acts",
		allow:       true,
		content:     `{"reply":"","command":"stay"}`,
		wantCommand: contract.CommandStay,
		wantSpoke:   false,
		wantReason:  contract.SilenceNothingToSay,
		prevents:    "a bot told to wait here having to say something about it first",
	}, {
		name:        "a reply with no command is an ordinary answer",
		allow:       true,
		content:     `{"reply":"Weiß ich nicht sicher."}`,
		wantCommand: contract.CommandNone,
		wantSpoke:   true,
		prevents:    "commands becoming mandatory once they are allowed",
	}, {
		name:        "an unknown command is ignored, and the reply survives",
		allow:       true,
		content:     `{"reply":"Ich komme.","command":"summon_demon"}`,
		wantCommand: contract.CommandNone,
		wantSpoke:   true,
		prevents:    "an invented command being guessed at, or costing a good sentence",
	}, {
		name:        "a command with an argument in it is not a command",
		allow:       true,
		content:     `{"reply":"Gut.","command":"attack Thrainn"}`,
		wantCommand: contract.CommandNone,
		wantSpoke:   true,
		prevents:    "the enum being used as a free-text argument channel",
	}, {
		name:        "a command that is not a string is ignored",
		allow:       true,
		content:     `{"reply":"Gut.","command":42}`,
		wantCommand: contract.CommandNone,
		wantSpoke:   true,
		prevents:    "a type confusion silencing a bot instead of dropping one field",
	}, {
		name:        "an empty command is the model declining, not an error",
		allow:       true,
		content:     `{"reply":"Gut.","command":""}`,
		wantCommand: contract.CommandNone,
		wantSpoke:   true,
		prevents:    "the prompt's own advice -- leave it empty when in doubt -- being punished",
	}, {
		name:        "a command offered when none was allowed is refused outright",
		allow:       false,
		content:     `{"reply":"Ich komme.","command":"follow"}`,
		wantCommand: contract.CommandNone,
		wantSpoke:   false,
		wantReason:  contract.SilenceFiltered,
		prevents:    "a model answering a question nobody asked being trusted about anything else",
	}}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := dialogueWithServer(t, func(w http.ResponseWriter, r *http.Request) {
				_, _ = w.Write([]byte(replyEnvelope(tc.content)))
			})
			req := dialogueFixture()
			req.AllowCommands = tc.allow
			resp, err := d.Speak(context.Background(), req)
			if err != nil {
				t.Fatalf("speak returned an error for a well-formed call: %v", err)
			}
			if resp.Command != tc.wantCommand {
				t.Fatalf("command = %q, want %q; prevents: %s", resp.Command, tc.wantCommand, tc.prevents)
			}
			if resp.Spoke != tc.wantSpoke {
				t.Fatalf("spoke = %v, want %v; prevents: %s", resp.Spoke, tc.wantSpoke, tc.prevents)
			}
			if tc.wantReason != "" && resp.Reason != tc.wantReason {
				t.Fatalf("reason = %q, want %q", resp.Reason, tc.wantReason)
			}
			if err := resp.Validate(); err != nil {
				t.Fatalf("Speak produced a response it would not send: %v", err)
			}
		})
	}
}

// A model that keeps asking for something this build removed should be visible,
// not merely inert.
func TestDialogueUnknownCommandsAreCounted(t *testing.T) {
	before := DialogueUnknownCommands()
	d := dialogueWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(replyEnvelope(`{"reply":"Ja.","command":"teleport"}`)))
	})
	req := dialogueFixture()
	req.AllowCommands = true
	if _, err := d.Speak(context.Background(), req); err != nil {
		t.Fatalf("speak: %v", err)
	}
	if got := DialogueUnknownCommands() - before; got != 1 {
		t.Fatalf("unknown commands counted = %d, want 1", got)
	}
}

// Every silence path must keep the command, because the two are independent.
//
// The one that matters is a reply this side refuses: the sentence is dropped and
// the command is not, because a filtered reply says nothing about whether the
// player asked the bot to come.
func TestDialogueFilteredReplyKeepsItsCommand(t *testing.T) {
	d := dialogueWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		// A reply reciting an internal trait key: leaksInternals refuses it.
		_, _ = w.Write([]byte(replyEnvelope(`{"reply":"Mein Trait ist wilderness_savvy.","command":"follow"}`)))
	})
	req := dialogueFixture()
	req.AllowCommands = true
	req.TraitKeys = []string{"wilderness_savvy"}
	resp, err := d.Speak(context.Background(), req)
	if err != nil {
		t.Fatalf("speak: %v", err)
	}
	if resp.Spoke || resp.Reason != contract.SilenceFiltered {
		t.Fatalf("a leaking reply was not filtered: %+v", resp)
	}
	if resp.Command != contract.CommandFollow {
		t.Fatalf("command = %q, want follow: a refused sentence must not cancel obedience", resp.Command)
	}
}
