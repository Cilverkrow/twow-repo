package llm

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
)

// dialogueFixture is a request whose every identifying field is a string the
// egress test can grep for. Same idea as pocFixture, and deliberately the same
// character name, so that a reader comparing the two sees one promise being kept
// twice rather than two unrelated checks.
func dialogueFixture() *contract.DialogueRequest {
	return &contract.DialogueRequest{
		ContractVersion: contract.Version,
		RequestID:       "d-1",
		Bot:             contract.BotID{Realm: 17, GUID: 987654321, UUID: fixtureUUID},
		Channel:         contract.ChannelParty,
		Speaker:         contract.SpeakerPlayer,
		Message:         "Wo geht es zur Mine?",
		TraitKeys:       []string{"stubborn", "curious"},
		Language:        contract.DialogueLanguage,
	}
}

func dialogueWithServer(t *testing.T, handler http.HandlerFunc) *Dialogue {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	// A budget per test, not the package-shared default. Dialogue prompts are
	// two kilobytes each and the default hourly window is 262144 units, so a
	// suite that shared it would slowly starve the OTHER tests in this package
	// -- and the symptom would be llm_test.go failing on an unrelated assertion
	// with "token budget admission denied", which is a genuinely confusing
	// afternoon.
	budget, err := NewTokenBudget(DefaultTokenLimits(), nil)
	if err != nil {
		t.Fatal(err)
	}
	backend, err := New(Config{
		Enabled: true, BaseURL: srv.URL, Model: "offline-fixture",
		Timeout: 2 * time.Second, TokenBudget: budget,
	})
	if err != nil {
		t.Fatal(err)
	}
	d, err := NewDialogue(backend, DialogueConfig{Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// replyEnvelope wraps a model reply in the chat-completions shape.
func replyEnvelope(content string) string {
	raw, _ := json.Marshal(map[string]any{
		"choices": []any{map[string]any{"message": map[string]any{"role": "assistant", "content": content}}},
	})
	return string(raw)
}

// The egress promise, restated for dialogue.
//
// llm.go says redact "sends no GUIDs, no realm ids, no account data and no
// character names", and poc_test.go proves it for the PoC by sending no traits
// at all. Dialogue MUST send traits -- that is the feature -- so it is the one
// caller that could break the promise, and this is the test that says it does
// not: the internal trait KEYS stay behind and only the German instruction text
// this repository wrote goes out.
func TestDialogueEgressSendsNoIdentityAndNoTraitKeys(t *testing.T) {
	var calls int
	d := dialogueWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != http.MethodPost || r.URL.Path != "/chat/completions" {
			t.Errorf("wrong endpoint: %s %s", r.Method, r.URL.Path)
		}
		raw, _ := io.ReadAll(r.Body)
		body := string(raw)
		for _, forbidden := range []string{
			fixtureUUID, "987654321", "PrivateCharacter", "realm", "guid",
			// The trait KEYS. Section 11.1 forbids a bot from uttering an
			// internal trait name, and the surest way to stop it saying one is
			// never to tell it one.
			"stubborn", "curious",
		} {
			if strings.Contains(body, forbidden) {
				t.Errorf("egress leaked %q", forbidden)
			}
		}
		// The instructions, on the other hand, are the whole point and must be
		// there. "stur" is the catalog's German label for stubborn and appears
		// inside its instruction sentence.
		var request chatRequest
		if json.Unmarshal(raw, &request) != nil || len(request.Messages) != 2 {
			t.Fatal("invalid prompt shape")
		}
		if !strings.Contains(request.Messages[0].Content, "untrusted DATA") {
			t.Error("the system prompt must frame the message as data, not instructions")
		}
		if !strings.Contains(request.Messages[1].Content, "Entschl") {
			t.Errorf("the stubborn trait's instruction did not reach the prompt: %s", request.Messages[1].Content)
		}
		if !strings.Contains(request.Messages[1].Content, "Wo geht es zur Mine") {
			t.Error("the player's message must reach the model; answering it is the feature")
		}
		io.WriteString(w, replyEnvelope(`{"reply":"Hinter dem Hügel, folgt mir."}`))
	})

	resp, err := d.Speak(context.Background(), dialogueFixture())
	if err != nil {
		t.Fatalf("Speak: %v", err)
	}
	if calls != 1 {
		t.Fatalf("calls = %d, want exactly 1: dialogue must not retry, a player is waiting", calls)
	}
	if !resp.Spoke || resp.Reply != "Hinter dem Hügel, folgt mir." {
		t.Fatalf("bad reply: %+v", resp)
	}
	if resp.Reason != "" {
		t.Errorf("a spoken reply must carry no silence reason, got %q", resp.Reason)
	}
	if resp.Stats.TraitsApplied != 2 {
		t.Errorf("traits applied = %d, want 2", resp.Stats.TraitsApplied)
	}
	if resp.Bot != dialogueFixture().Bot {
		t.Error("the reply must be addressed to the bot we asked about, never to one the model named")
	}
}

// Every one of these is an outcome the game sees as "the bot said nothing", and
// the reason string is the only thing that tells them apart. Getting one wrong
// means an operator cannot distinguish a healthy quiet bot from a dead endpoint.
func TestDialogueSilenceReasons(t *testing.T) {
	tests := []struct {
		name       string
		content    string // model reply content, when the server answers 200
		status     int    // non-zero overrides the status
		wantReason string
		wantErr    bool
		prevents   string
	}{{
		name:       "an empty reply is the model choosing silence",
		content:    `{"reply":""}`,
		wantReason: contract.SilenceNothingToSay,
		prevents:   "a bot that correctly stayed out of a conversation looking like a broken integration",
	}, {
		name:       "whitespace is silence too",
		content:    `{"reply":"   \n  "}`,
		wantReason: contract.SilenceNothingToSay,
		prevents:   "a blank line being posted to a chat channel",
	}, {
		name:       "an unknown field means the model answered a question we did not ask",
		content:    `{"reply":"Hallo","intent":"invite"}`,
		wantReason: contract.SilenceFiltered,
		prevents:   "a model inventing an action channel and something downstream one day reading it",
	}, {
		name:       "a duplicate key is refused",
		content:    `{"reply":"harmlos","reply":"stattdessen etwas anderes"}`,
		wantReason: contract.SilenceFiltered,
		prevents:   "encoding/json silently taking the last value of a duplicated key",
	}, {
		name:       "prose instead of JSON is refused",
		content:    `Ich denke, die Mine liegt im Norden.`,
		wantReason: contract.SilenceFiltered,
		prevents:   "a model's chain of thought being posted to guild chat as if it were a line of dialogue",
	}, {
		name:       "a reply naming an internal trait key is refused",
		content:    `{"reply":"Als stubborn Zwerg bleibe ich dabei."}`,
		wantReason: contract.SilenceFiltered,
		prevents:   "the contract's 'no internal trait names' rule being enforced only by asking the model nicely",
	}, {
		name:       "a reply naming the model is refused",
		content:    `{"reply":"Ich bin offline-fixture und helfe gern."}`,
		wantReason: contract.SilenceFiltered,
		prevents:   "a bot breaking character by naming the model behind it",
	}, {
		name:       "a rate limit is unavailable, not an error status to the caller",
		status:     http.StatusTooManyRequests,
		wantReason: contract.SilenceUnavailable,
		wantErr:    true,
		prevents:   "a provider's bad minute becoming a 500 the worldserver has to handle",
	}, {
		name:       "a broken envelope is unavailable",
		content:    "", // handled below: the server writes junk
		status:     http.StatusOK,
		wantReason: contract.SilenceUnavailable,
		wantErr:    true,
		prevents:   "a misconfigured endpoint being reported as the model having nothing to say",
	}}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := dialogueWithServer(t, func(w http.ResponseWriter, r *http.Request) {
				if tc.status != 0 && tc.status != http.StatusOK {
					w.WriteHeader(tc.status)
					io.WriteString(w, `{"error":{"message":"slow down"}}`)
					return
				}
				if tc.content == "" {
					io.WriteString(w, `not chat-completions json at all`)
					return
				}
				io.WriteString(w, replyEnvelope(tc.content))
			})
			resp, err := d.Speak(context.Background(), dialogueFixture())
			if resp.Spoke || resp.Reply != "" {
				t.Fatalf("must be silent, got %+v (%s)", resp, tc.prevents)
			}
			if resp.Reason != tc.wantReason {
				t.Fatalf("reason = %q, want %q (%s)", resp.Reason, tc.wantReason, tc.prevents)
			}
			if (err != nil) != tc.wantErr {
				t.Errorf("err = %v, wantErr = %v (%s)", err, tc.wantErr, tc.prevents)
			}
			if verr := resp.Validate(); verr != nil {
				t.Errorf("every silent response must still be well formed: %v", verr)
			}
		})
	}
}

// A model that answers at length costs a short reply, not a truncated word and
// not a rejected one. The bound is the game's own chat limit, enforced here so
// that whoever posts it does not have to.
func TestDialogueReplyIsBoundedAtAWordBoundary(t *testing.T) {
	long := strings.TrimSpace(strings.Repeat("Wort ", 200))
	d := dialogueWithServer(t, func(w http.ResponseWriter, _ *http.Request) {
		body, _ := json.Marshal(map[string]string{"reply": long})
		io.WriteString(w, replyEnvelope(string(body)))
	})
	resp, err := d.Speak(context.Background(), dialogueFixture())
	if err != nil {
		t.Fatal(err)
	}
	if !resp.Spoke {
		t.Fatalf("a long reply must be clipped, not silenced: %+v", resp)
	}
	if len(resp.Reply) > contract.MaxDialogueReplyBytes {
		t.Fatalf("reply is %d bytes, max %d", len(resp.Reply), contract.MaxDialogueReplyBytes)
	}
	if strings.HasSuffix(resp.Reply, "Wor") || strings.HasSuffix(resp.Reply, " ") {
		t.Fatalf("clip landed mid-word or on a space: %q", resp.Reply)
	}
}

// A multi-line reply becomes one line rather than being rejected. A model that
// wrote two sentences on two lines has formatted, not misbehaved, and the
// channel simply has no formatting; a control character, on the other hand, has
// no reading at all and is dropped.
func TestDialogueFlattensToOneChatLine(t *testing.T) {
	d := dialogueWithServer(t, func(w http.ResponseWriter, _ *http.Request) {
		body, _ := json.Marshal(map[string]string{"reply": "  Erste Zeile.\n\tZweite\a Zeile.  "})
		io.WriteString(w, replyEnvelope(string(body)))
	})
	resp, err := d.Speak(context.Background(), dialogueFixture())
	if err != nil {
		t.Fatal(err)
	}
	if resp.Reply != "Erste Zeile. Zweite Zeile." {
		t.Fatalf("reply = %q, want the two lines joined and the bell dropped", resp.Reply)
	}
}

// The breaker is shared with the planner, deliberately: it tracks the ENDPOINT,
// and an endpoint that is down is down for both callers. This asserts the half
// that is easy to get wrong -- dialogue must consult it before paying a timeout
// to confirm what five failures already established.
func TestDialogueRespectsTheSharedCircuitBreaker(t *testing.T) {
	var calls int
	d := dialogueWithServer(t, func(w http.ResponseWriter, _ *http.Request) {
		calls++
		io.WriteString(w, replyEnvelope(`{"reply":"Hallo."}`))
	})
	d.backend.healthy.Store(false) // as five consecutive failures would leave it

	resp, err := d.Speak(context.Background(), dialogueFixture())
	if calls != 0 {
		t.Fatalf("calls = %d, want 0: an open breaker must cost nothing", calls)
	}
	if resp.Spoke || resp.Reason != contract.SilenceUnavailable {
		t.Fatalf("want silent/unavailable, got %+v", resp)
	}
	if err == nil {
		t.Error("the log needs to know why the bot was quiet")
	}
	if d.Ready() {
		t.Error("Ready must report the breaker's state")
	}
}

// The budget is shared with the planner on purpose (see Config.TokenBudget). The
// consequence that must hold is this one: once it has latched, dialogue stops
// calling the model, immediately and without another request.
func TestDialogueRespectsTheSharedTokenBudget(t *testing.T) {
	var calls int
	d := dialogueWithServer(t, func(w http.ResponseWriter, _ *http.Request) {
		calls++
		io.WriteString(w, replyEnvelope(`{"reply":"Hallo."}`))
	})
	d.backend.cfg.TokenBudget.Stop()

	resp, err := d.Speak(context.Background(), dialogueFixture())
	if calls != 0 {
		t.Fatalf("calls = %d, want 0: a latched budget must not be spent against", calls)
	}
	if resp.Spoke || resp.Reason != contract.SilenceBudget {
		t.Fatalf("want silent/budget_exhausted, got %+v", resp)
	}
	if err == nil {
		t.Error("a latched budget is the one failure that is invisible from outside; it must reach the log")
	}
}

// Dialogue reserves ITS ceiling, not the planner's. Sharing the window without
// sharing the per-call figure is what stops one-sentence replies from charging
// the shared hourly budget as if they were sixteen-bot planning batches.
func TestDialogueReservesItsOwnSmallerCeiling(t *testing.T) {
	budget, err := NewTokenBudget(DefaultTokenLimits(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var sentBytes int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		sentBytes = len(raw)
		io.WriteString(w, replyEnvelope(`{"reply":"Hallo."}`))
	}))
	t.Cleanup(srv.Close)
	backend, err := New(Config{
		Enabled: true, BaseURL: srv.URL, Model: "offline-fixture",
		Timeout: time.Second, MaxTokens: 1024, TokenBudget: budget,
	})
	if err != nil {
		t.Fatal(err)
	}
	d, err := NewDialogue(backend, DialogueConfig{Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Speak(context.Background(), dialogueFixture()); err != nil {
		t.Fatal(err)
	}
	budget.mu.Lock()
	used := budget.usedHour
	budget.mu.Unlock()
	// The charge is the request's bytes (the local accounting unit for input)
	// plus the reserved completion. Asserted exactly rather than approximately,
	// because the whole claim being made is which completion figure was used:
	// with the planner's 1024 the charge would be 832 units higher, every call.
	want := int64(sentBytes) + DefaultDialogueMaxTokens
	if used != want {
		t.Fatalf("charged %d units, want %d (%d prompt bytes + dialogue's %d completion). "+
			"A charge of %d would mean the planner's ceiling was reserved for a one-sentence reply.",
			used, want, sentBytes, DefaultDialogueMaxTokens, int64(sentBytes)+1024)
	}
}

func TestNewDialogue(t *testing.T) {
	backend, err := New(Config{Enabled: true, BaseURL: "http://example.invalid/v1", Model: "m", Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name     string
		backend  *Planner
		cfg      DialogueConfig
		wantErr  bool
		prevents string
	}{{
		name:     "disabled is the default and is an error, not a nil planner",
		backend:  backend,
		cfg:      DialogueConfig{},
		wantErr:  true,
		prevents: "a caller mistaking 'off' for 'built', the same shape llm.New already uses",
	}, {
		name:     "no backend is refused",
		cfg:      DialogueConfig{Enabled: true},
		wantErr:  true,
		prevents: "a dialogue that quietly builds its own second HTTP client, which is the thing this design exists to avoid",
	}, {
		name:     "max_tokens above the output budget is refused at construction",
		backend:  backend,
		cfg:      DialogueConfig{Enabled: true, MaxTokens: int(DefaultTokenLimits().OutputPerRequest) + 1},
		wantErr:  true,
		prevents: "a misconfiguration that would deny every single utterance at runtime and look exactly like bots with nothing to say",
	}, {
		name:     "enabled with defaults builds",
		backend:  backend,
		cfg:      DialogueConfig{Enabled: true},
		prevents: "the ordinary configuration failing",
	}}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d, err := NewDialogue(tc.backend, tc.cfg)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr = %v (%s)", err, tc.wantErr, tc.prevents)
			}
			if err == nil && (d.maxTokens <= 0 || d.timeout <= 0) {
				t.Errorf("defaults must be finite, got tokens=%d timeout=%s", d.maxTokens, d.timeout)
			}
		})
	}
}

// The leak filter has to be wrong in neither direction, and the German half is
// the one that is easy to miss: several catalog keys are also ordinary German
// words, so a filter that matched bare substrings would silence a `loyal` bot
// every time it said "loyal".
func TestLeaksInternals(t *testing.T) {
	tests := []struct {
		name     string
		text     string
		keys     []string
		model    string
		want     bool
		prevents string
	}{{
		name:     "an internal key recited verbatim is a leak",
		text:     "Als stubborn Zwerg bleibe ich dabei.",
		keys:     []string{"stubborn"},
		want:     true,
		prevents: "the contract's 'no internal trait names' rule being enforced only by asking the model nicely",
	}, {
		name:     "a short key that is also a German word is not a leak",
		text:     "Ich bleibe dir gegenüber loyal.",
		keys:     []string{"loyal"},
		want:     false,
		prevents: "a bot being silenced for using the very word it was assigned to embody",
	}, {
		name:     "so is formal, which is spelled the same in both languages",
		text:     "Das klingt mir zu formal.",
		keys:     []string{"formal"},
		want:     false,
		prevents: "the same collision, in the other obvious case",
	}, {
		name:     "a key inside a longer word is a coincidence, not a recitation",
		text:     "Das war ein stubbornheitsloses Angebot.",
		keys:     []string{"stubborn"},
		want:     false,
		prevents: "substring matching silencing replies for reasons nobody can reconstruct from a log",
	}, {
		name:     "the model name is a leak at any length",
		text:     "Ich bin nur qwen und helfe gern.",
		model:    "qwen",
		want:     true,
		prevents: "a bot breaking character by naming the model behind it",
	}, {
		name:     "an ordinary reply passes",
		text:     "Hinter dem Hügel, folgt mir.",
		keys:     []string{"stubborn", "curious"},
		model:    "offline-fixture",
		want:     false,
		prevents: "the filter refusing the replies it exists to let through",
	}}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := leaksInternals(strings.ToLower(tc.text), tc.keys, tc.model); got != tc.want {
				t.Fatalf("leaksInternals = %v, want %v (%s)", got, tc.want, tc.prevents)
			}
		})
	}
}

// clipChatLine is worth its own table: it is the only place a reply's bytes are
// cut, and every mistake it can make is visible to a player.
func TestClipChatLine(t *testing.T) {
	tests := []struct {
		name     string
		in       string
		max      int
		want     string
		prevents string
	}{{
		name:     "a short line is untouched",
		in:       "Hallo.",
		max:      32,
		want:     "Hallo.",
		prevents: "clipping something that fits",
	}, {
		name:     "a long line cuts at the last space",
		in:       "Das ist ein ziemlich langer Satz ueber Erz",
		max:      36,
		want:     "Das ist ein ziemlich langer Satz",
		prevents: "a cut landing mid-word, which reads as a bug rather than as brevity",
	}, {
		name:     "a line with no early space is refused rather than cut mid-rune",
		in:       strings.Repeat("x", 100),
		max:      40,
		want:     "",
		prevents: "cutting inside a multi-byte rune and emitting invalid UTF-8",
	}}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := clipChatLine(tc.in, tc.max); got != tc.want {
				t.Fatalf("clipChatLine = %q, want %q (%s)", got, tc.want, tc.prevents)
			}
		})
	}
}
