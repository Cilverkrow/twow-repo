package httpapi_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/httpapi"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/metrics"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// fakeSpeaker stands in for *llm.Dialogue. It exists so this package can be
// tested without importing the LLM client, which is the same reason the Speaker
// interface is declared on this side in the first place.
type fakeSpeaker struct {
	mu    sync.Mutex
	calls int
	// hold, when non-nil, blocks Speak until it is closed, and entered is closed
	// as soon as Speak is inside. Together they fill the in-flight limit
	// deterministically: without entered the second request could win the race
	// and the shedding test would assert nothing.
	hold    chan struct{}
	entered chan struct{}
	reply   contract.DialogueResponse
	err     error
}

func (f *fakeSpeaker) Speak(ctx context.Context, req *contract.DialogueRequest) (contract.DialogueResponse, error) {
	f.mu.Lock()
	f.calls++
	first := f.calls == 1
	f.mu.Unlock()
	if first && f.entered != nil {
		close(f.entered)
	}
	if f.hold != nil {
		<-f.hold
	}
	out := f.reply
	out.Bot = req.Bot
	return out, f.err
}

func (f *fakeSpeaker) Ready() bool { return true }

func (f *fakeSpeaker) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func newDialogueServer(t *testing.T, sp httpapi.Speaker, inFlight int) (*httpapi.Server, *metrics.Registry) {
	t.Helper()
	reg := metrics.New()
	return httpapi.New(httpapi.Options{
		Planner:             rule.New(rule.Thresholds{}),
		Metrics:             reg,
		Dialogue:            sp,
		MaxDialogueInFlight: inFlight,
	}), reg
}

func dialogueBody() string {
	return `{"contract_version":"` + contract.Version + `","request_id":"d-1",` +
		`"bot":{"realm":1,"guid":42},"channel":"say","speaker":"player",` +
		`"message":"Wo geht es zur Mine?","trait_keys":["curious"]}`
}

func postDialogue(t *testing.T, srv *httpapi.Server, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/dialogue", strings.NewReader(body))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

func decodeDialogue(t *testing.T, rec *httptest.ResponseRecorder) contract.DialogueResponse {
	t.Helper()
	var resp contract.DialogueResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding response: %v\nbody: %s", err, rec.Body.String())
	}
	return resp
}

// The shape decision the whole endpoint rests on: a request that decoded is
// answered with 200, whatever happened afterwards. If silence were an error the
// C++ side would learn to ignore errors here, and a real failure would then be
// invisible.
func TestDialogueSilenceIsA200(t *testing.T) {
	tests := []struct {
		name     string
		speaker  httpapi.Speaker
		wantCode int
		wantSaid bool
		wantWhy  string
		prevents string
	}{{
		name:     "no speaker configured",
		speaker:  nil,
		wantCode: http.StatusOK,
		wantWhy:  contract.SilenceDisabled,
		prevents: "a deployment with inference off -- the default -- answering 404 or 501 and giving the caller a third outcome to handle",
	}, {
		name:     "the backend could not reach a model",
		speaker:  &fakeSpeaker{reply: contract.DialogueResponse{Reason: contract.SilenceUnavailable}},
		wantCode: http.StatusOK,
		wantWhy:  contract.SilenceUnavailable,
		prevents: "a provider outage becoming a 5xx the worldserver has to treat as its own failure",
	}, {
		name:     "the model chose not to answer",
		speaker:  &fakeSpeaker{reply: contract.DialogueResponse{Reason: contract.SilenceNothingToSay}},
		wantCode: http.StatusOK,
		wantWhy:  contract.SilenceNothingToSay,
		prevents: "the healthy and most common outcome being reported as a problem",
	}, {
		name:     "a reply",
		speaker:  &fakeSpeaker{reply: contract.DialogueResponse{Spoke: true, Reply: "Hinter dem Hügel."}},
		wantCode: http.StatusOK,
		wantSaid: true,
		prevents: "the happy path breaking unnoticed",
	}}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := newDialogueServer(t, tc.speaker, 0)
			rec := postDialogue(t, srv, dialogueBody())
			if rec.Code != tc.wantCode {
				t.Fatalf("status = %d, want %d (%s)", rec.Code, tc.wantCode, tc.prevents)
			}
			resp := decodeDialogue(t, rec)
			if resp.Spoke != tc.wantSaid {
				t.Fatalf("spoke = %v, want %v (%s)", resp.Spoke, tc.wantSaid, tc.prevents)
			}
			if resp.Reason != tc.wantWhy {
				t.Fatalf("reason = %q, want %q (%s)", resp.Reason, tc.wantWhy, tc.prevents)
			}
			if resp.RequestID != "d-1" {
				t.Errorf("request_id = %q, want the caller's, so the two logs join", resp.RequestID)
			}
			if resp.Bot.GUID != 42 {
				t.Errorf("bot = %v, want the one asked about", resp.Bot)
			}
			if resp.ContractVersion == "" {
				t.Error("every response must be stamped with the negotiated version")
			}
		})
	}
}

// A decode failure IS an error status, and this is the only way to get one.
// A malformed dialogue request has no partial success to preserve -- there is
// one bot, not a thousand -- so the caller should hear about it at once.
func TestDialogueDecodeErrors(t *testing.T) {
	tests := []struct {
		name      string
		body      string
		wantCode  int
		wantCode2 string
		prevents  string
	}{{
		name:      "a different contract major is a 409",
		body:      strings.Replace(dialogueBody(), `"`+contract.Version+`"`, `"9.0"`, 1),
		wantCode:  http.StatusConflict,
		wantCode2: contract.CodeVersionSkew,
		prevents:  "a skewed peer being served data it may misread, instead of falling back to in-core behaviour",
	}, {
		name:      "an unknown channel is a 400",
		body:      strings.Replace(dialogueBody(), `"channel":"say"`, `"channel":"raid"`, 1),
		wantCode:  http.StatusBadRequest,
		wantCode2: contract.CodeMalformed,
		prevents:  "an unrecognised channel being silently treated as say",
	}, {
		name:      "an over-long body is a 413",
		body:      `{"contract_version":"` + contract.Version + `","junk":"` + strings.Repeat("a", contract.DefaultMaxDialogueBodyBytes+64) + `"}`,
		wantCode:  http.StatusRequestEntityTooLarge,
		wantCode2: contract.CodeBatchTooLarge,
		prevents:  "an over-sized body coming back as 400 'malformed JSON' and sending the operator to hunt a bug in their encoder",
	}}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := newDialogueServer(t, &fakeSpeaker{}, 0)
			rec := postDialogue(t, srv, tc.body)
			if rec.Code != tc.wantCode {
				t.Fatalf("status = %d, want %d (%s)\nbody: %s", rec.Code, tc.wantCode, tc.prevents, rec.Body.String())
			}
			var env struct {
				Code string `json:"code"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
				t.Fatalf("error envelope did not decode: %v", err)
			}
			if env.Code != tc.wantCode2 {
				t.Fatalf("code = %q, want %q (%s)", env.Code, tc.wantCode2, tc.prevents)
			}
		})
	}
}

// The body cap must apply BEFORE the decoder, which is the whole reason it
// exists: the endpoint is unauthenticated and the decoder does not run until the
// body is in memory. The plan endpoint's 16 MiB is three orders of magnitude too
// generous for one line of chat.
func TestDialogueBodyCapIsFarBelowThePlanCap(t *testing.T) {
	if contract.DefaultMaxDialogueBodyBytes >= contract.DefaultMaxBodyBytes/1000 {
		t.Fatalf("dialogue body cap %d is not meaningfully below the plan cap %d",
			contract.DefaultMaxDialogueBodyBytes, contract.DefaultMaxBodyBytes)
	}
}

// Requests over the in-flight limit are shed immediately rather than queued. A
// queue here would accumulate load during exactly the incident where
// accumulating load is fatal, and would hold the worldserver's connections open
// while it did.
func TestDialogueShedsWhenTooManyAreInFlight(t *testing.T) {
	hold := make(chan struct{})
	sp := &fakeSpeaker{
		hold:    hold,
		entered: make(chan struct{}),
		reply:   contract.DialogueResponse{Spoke: true, Reply: "Hallo."},
	}
	srv, reg := newDialogueServer(t, sp, 1)

	// Occupy the single slot, and wait until it is genuinely occupied.
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		req := httptest.NewRequest(http.MethodPost, "/v1/dialogue", strings.NewReader(dialogueBody()))
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		done <- rec
	}()
	<-sp.entered

	rec := postDialogue(t, srv, dialogueBody())
	if rec.Code != http.StatusOK {
		t.Fatalf("a shed request is still a 200: got %d", rec.Code)
	}
	resp := decodeDialogue(t, rec)
	if resp.Spoke || resp.Reason != contract.SilenceBusy {
		t.Fatalf("want silent/busy, got %+v", resp)
	}
	if sp.callCount() != 1 {
		t.Fatalf("the shed request must not reach the model: calls = %d", sp.callCount())
	}
	if !strings.Contains(reg.String(), httpapi.MetricDialogueSilence) {
		t.Error("shedding must be visible in metrics, or it looks like bots simply had nothing to say")
	}

	close(hold)
	if first := <-done; first.Code != http.StatusOK {
		t.Fatalf("the admitted request must still succeed: %d", first.Code)
	}
}

// A backend that returns something self-contradictory is silenced rather than
// posted. This is the last gate before text this service did not write reaches a
// game channel, and it must not trust the layer below it.
func TestDialogueSilencesAnInvalidBackendResponse(t *testing.T) {
	sp := &fakeSpeaker{reply: contract.DialogueResponse{
		Spoke: true,
		// Two lines where the channel agreed to one. llm.Dialogue would never
		// produce this; the point is that the handler does not assume so.
		Reply: "erste\nzweite",
	}}
	srv, _ := newDialogueServer(t, sp, 0)
	resp := decodeDialogue(t, postDialogue(t, srv, dialogueBody()))
	if resp.Spoke || resp.Reason != contract.SilenceFiltered {
		t.Fatalf("want silent/filtered, got %+v", resp)
	}
}

// A backend must not be able to re-address a reply to a bot the caller did not
// ask about. Same reasoning as the unasked-bot drop on the plan path: a bug
// below must never deliver to the wrong character.
func TestDialogueReplyIsAlwaysAddressedToTheBotAskedAbout(t *testing.T) {
	sp := &fakeSpeaker{reply: contract.DialogueResponse{
		Spoke: true, Reply: "Hallo.",
		Bot: contract.BotID{Realm: 99, GUID: 12345},
	}}
	srv, _ := newDialogueServer(t, sp, 0)
	resp := decodeDialogue(t, postDialogue(t, srv, dialogueBody()))
	if resp.Bot.Realm != 1 || resp.Bot.GUID != 42 {
		t.Fatalf("reply addressed to %v, want the bot in the request", resp.Bot)
	}
}

// The contract endpoint is how the C++ side discovers what this build speaks. A
// dialogue-capable build must announce a minor that says so, or the caller has
// to probe the route to find out.
func TestContractInfoAnnouncesTheDialogueMinor(t *testing.T) {
	srv, _ := newDialogueServer(t, nil, 0)
	rec := get(t, srv, "/v1/contract")
	var info contract.ContractInfo
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Version != contract.Version {
		t.Fatalf("version = %q, want %q", info.Version, contract.Version)
	}
	if contract.VersionMinor < 3 {
		t.Fatal("the dialogue endpoint is an additive contract change and must carry at least minor 3")
	}
}
