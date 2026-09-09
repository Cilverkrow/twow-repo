package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

// The transport must carry a command through untouched when it was asked for.
func TestDialogueEndpointForwardsAnAllowedCommand(t *testing.T) {
	sp := &fakeSpeaker{reply: contract.DialogueResponse{
		Spoke: true, Reply: "Ich komme.", Command: contract.CommandFollow,
	}}
	srv, _ := newDialogueServer(t, sp, 0)

	body := strings.Replace(dialogueBody(), `"request_id":"d-1",`, `"request_id":"d-1","allow_commands":true,`, 1)
	rec := postDialogue(t, srv, body)
	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var resp contract.DialogueResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Command != contract.CommandFollow {
		t.Fatalf("command = %q, want follow", resp.Command)
	}
	if !strings.Contains(rec.Body.String(), `"command":"follow"`) {
		t.Fatalf("command did not reach the wire under its own name: %s", rec.Body.String())
	}
}

// A command for a request that did not allow one is dropped at the transport,
// not merely relied upon to have been dropped further down.
//
// The backend already refuses to offer the vocabulary unless the request asked
// for it, so this can only fire if something below let one through -- and the
// safe reading of that is the reply, without the command. Two layers refusing
// the same thing is the point: this one is the layer that reads the request the
// worldserver actually sent.
func TestDialogueEndpointDropsACommandNobodyAllowed(t *testing.T) {
	sp := &fakeSpeaker{reply: contract.DialogueResponse{
		Spoke: true, Reply: "Ich komme.", Command: contract.CommandFollow,
	}}
	srv, _ := newDialogueServer(t, sp, 0)

	// dialogueBody() has no allow_commands, so it is text only.
	rec := postDialogue(t, srv, dialogueBody())
	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var resp contract.DialogueResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Command != contract.CommandNone {
		t.Fatalf("command = %q, want none: a request that did not allow commands got one", resp.Command)
	}
	if !resp.Spoke || resp.Reply != "Ich komme." {
		t.Fatalf("the reply was punished for the command: %+v", resp)
	}
}

// A response whose own validation fails is rebuilt from nothing, command
// included. Two checks in this service disagreeing is not a state to take an
// action from.
func TestDialogueEndpointSilencesAnInvalidResponseIncludingItsCommand(t *testing.T) {
	sp := &fakeSpeaker{reply: contract.DialogueResponse{
		// Spoke with no reply: Validate refuses it.
		Spoke: true, Reply: "", Command: contract.CommandAttack,
	}}
	srv, _ := newDialogueServer(t, sp, 0)

	body := strings.Replace(dialogueBody(), `"request_id":"d-1",`, `"request_id":"d-1","allow_commands":true,`, 1)
	rec := postDialogue(t, srv, body)
	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var resp contract.DialogueResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Spoke || resp.Reason != contract.SilenceFiltered {
		t.Fatalf("an invalid response was not silenced: %+v", resp)
	}
	if resp.Command != contract.CommandNone {
		t.Fatalf("command = %q, want none: an invalid response kept its command", resp.Command)
	}
}
