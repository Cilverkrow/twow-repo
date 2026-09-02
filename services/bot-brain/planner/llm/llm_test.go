package llm_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/llm"
)

// Every test here runs against httptest on loopback. Nothing reaches a real
// model, and `go test ./...` needs no network.

func f(v float64) *float64 { return &v }

func snap(guid uint64) contract.Snapshot {
	return contract.Snapshot{
		Bot:  contract.BotID{Realm: 1, GUID: guid},
		Char: contract.Character{Name: "Secretname", Level: 25, Class: 2, Faction: "horde", FreeBagSlots: 4},
		Pos:  contract.Position{MapID: 1, X: 500, Y: 600, Z: 70},
		Vit:  contract.Vitals{HealthPct: 88, DurabilityPct: f(60)},
		POIs: []contract.PointOfInterest{
			{ID: "p1", Kind: "grind_area", Pos: contract.Position{MapID: 1}, DistanceYards: f(120)},
			{ID: "p2", Kind: "quest_turnin", Pos: contract.Position{MapID: 1}, DistanceYards: f(300), RelatedQuestID: 42},
		},
		Quests: []contract.QuestEntry{{QuestID: 42, Status: "complete"}},
	}
}

// completion serves a fixed chat-completions body.
func completion(t *testing.T, content string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"choices": []map[string]any{{"message": map[string]string{"role": "assistant", "content": content}}},
		})
	}))
}

func newPlanner(t *testing.T, baseURL string, mutate func(*llm.Config)) *llm.Planner {
	t.Helper()
	cfg := llm.Config{
		Enabled: true, BaseURL: baseURL, Model: "test-model",
		Timeout: 2 * time.Second, MaxBotsPerCall: 16,
	}
	if mutate != nil {
		mutate(&cfg)
	}
	p, err := llm.New(cfg)
	if err != nil {
		t.Fatalf("llm.New: %v", err)
	}
	return p
}

func TestNewConfigValidation(t *testing.T) {
	tests := []struct {
		name    string
		cfg     llm.Config
		wantErr string
	}{
		{
			name:    "disabled",
			cfg:     llm.Config{Enabled: false},
			wantErr: "disabled",
		},
		{
			name:    "no base url",
			cfg:     llm.Config{Enabled: true, Model: "m"},
			wantErr: "base URL",
		},
		{
			name:    "no model",
			cfg:     llm.Config{Enabled: true, BaseURL: "http://x/v1"},
			wantErr: "model is required",
		},
		{
			name: "model not in the allowlist",
			cfg: llm.Config{Enabled: true, BaseURL: "http://x/v1", Model: "gpt-expensive",
				AllowedModels: []string{"qwen2.5-7b", "llama-3.1-8b"}},
			wantErr: "allowlist",
		},
		{
			name: "model in the allowlist",
			cfg: llm.Config{Enabled: true, BaseURL: "http://x/v1", Model: "qwen2.5-7b",
				AllowedModels: []string{"qwen2.5-7b"}},
		},
		{
			name: "local endpoint with no key is fine",
			cfg:  llm.Config{Enabled: true, BaseURL: "http://vllm:8000/v1", Model: "qwen2.5-7b"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := llm.New(tc.cfg)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("err = %v, want one containing %q", err, tc.wantErr)
			}
		})
	}
}

func TestProviderAuthHeaders(t *testing.T) {
	tests := []struct {
		name     string
		provider llm.Provider
		key      string
		wantHdr  string
		wantVal  string
		absent   string
	}{
		{name: "openai style bearer", provider: llm.ProviderOpenAI, key: "sk-123",
			wantHdr: "Authorization", wantVal: "Bearer sk-123"},
		{name: "vllm with no key sends no auth header", provider: llm.ProviderOpenAI, key: "",
			absent: "Authorization"},
		{name: "azure", provider: llm.ProviderAzure, key: "azkey",
			wantHdr: "api-key", wantVal: "azkey"},
		{name: "anthropic", provider: llm.ProviderAnthropic, key: "ak",
			wantHdr: "x-api-key", wantVal: "ak"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var got http.Header
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				got = r.Header.Clone()
				w.Header().Set("Content-Type", "application/json")
				_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"{\"intents\":[]}"}}]}`)
			}))
			defer srv.Close()

			p := newPlanner(t, srv.URL+"/v1", func(c *llm.Config) {
				c.Provider = tc.provider
				c.APIKey = tc.key
			})
			_, _ = p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{snap(1)}})

			if tc.wantHdr != "" && got.Get(tc.wantHdr) != tc.wantVal {
				t.Errorf("%s = %q, want %q", tc.wantHdr, got.Get(tc.wantHdr), tc.wantVal)
			}
			if tc.absent != "" && got.Get(tc.absent) != "" {
				t.Errorf("%s was sent (%q) but should have been omitted", tc.absent, got.Get(tc.absent))
			}
			if tc.provider == llm.ProviderAnthropic && got.Get("anthropic-version") != llm.AnthropicVersion {
				t.Errorf("anthropic-version = %q, want %q", got.Get("anthropic-version"), llm.AnthropicVersion)
			}
		})
	}
}

// The egress filter is the security boundary for ARCH-003. Nothing that
// identifies a bot, an account or a player may reach a third party.
func TestPromptCarriesNoIdentifiers(t *testing.T) {
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		body = string(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"{\"intents\":[]}"}}]}`)
	}))
	defer srv.Close()

	p := newPlanner(t, srv.URL+"/v1", nil)
	s := snap(31337)
	if _, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{s}}); err != nil {
		t.Fatalf("Plan: %v", err)
	}

	forbidden := []string{"Secretname", "31337", "realm"}
	for _, bad := range forbidden {
		if strings.Contains(body, bad) {
			t.Errorf("prompt leaked %q; the egress filter must not send identifiers.\nbody: %s", bad, body)
		}
	}
	// It should still carry the things planning actually needs.
	for _, want := range []string{"p1", "p2", "grind_area"} {
		if !strings.Contains(body, want) {
			t.Errorf("prompt is missing %q, which the model needs to choose a destination", want)
		}
	}
}

func TestParsingModelReplies(t *testing.T) {
	tests := []struct {
		name        string
		content     string
		wantIntents int
		wantKind    contract.IntentKind
		wantPOI     string
		why         string
	}{
		{
			name:        "clean json",
			content:     `{"intents":[{"bot":0,"kind":"travel_to","poi_id":"p1","certainty":0.8,"why":"grinding"}]}`,
			wantIntents: 1, wantKind: contract.IntentTravelTo, wantPOI: "p1",
		},
		{
			name:        "json wrapped in prose and a code fence",
			content:     "Sure! Here is the plan:\n```json\n{\"intents\":[{\"bot\":0,\"kind\":\"rest\"}]}\n```\nHope that helps.",
			wantIntents: 1, wantKind: contract.IntentRest,
			why: "models wrap JSON no matter how firmly they are asked not to",
		},
		{
			name:        "hallucinated poi id is dropped",
			content:     `{"intents":[{"bot":0,"kind":"travel_to","poi_id":"p_invented"}]}`,
			wantIntents: 0,
			why:         "the bot then falls back to rules, which is a worse plan but a real one",
		},
		{
			name:        "unknown kind is dropped",
			content:     `{"intents":[{"bot":0,"kind":"delete_character","poi_id":"p1"}]}`,
			wantIntents: 0,
			why:         "the closed kind set is how invariant 1 is enforced against a model",
		},
		{
			name:        "out of range bot index is dropped",
			content:     `{"intents":[{"bot":7,"kind":"rest"}]}`,
			wantIntents: 0,
		},
		{
			name:        "negative bot index is dropped",
			content:     `{"intents":[{"bot":-1,"kind":"rest"}]}`,
			wantIntents: 0,
		},
		{
			name:        "duplicate bot index keeps only the first",
			content:     `{"intents":[{"bot":0,"kind":"rest"},{"bot":0,"kind":"idle"}]}`,
			wantIntents: 1, wantKind: contract.IntentRest,
		},
		{
			name:        "abandon of a quest not in the log is dropped",
			content:     `{"intents":[{"bot":0,"kind":"abandon_quest","quest_id":9999}]}`,
			wantIntents: 0,
		},
		{
			name:        "abandon of a quest in the log is kept",
			content:     `{"intents":[{"bot":0,"kind":"abandon_quest","quest_id":42}]}`,
			wantIntents: 1, wantKind: contract.IntentAbandonQuest,
		},
		{
			name:        "kind is case and whitespace tolerant",
			content:     `{"intents":[{"bot":0,"kind":"  REST "}]}`,
			wantIntents: 1, wantKind: contract.IntentRest,
		},
		{
			name:        "not json at all",
			content:     "I'm sorry, I can't help with that.",
			wantIntents: 0,
		},
		{
			name:        "truncated json",
			content:     `{"intents":[{"bot":0,"kind":"rest"`,
			wantIntents: 0,
		},
		{
			name:        "empty intents",
			content:     `{"intents":[]}`,
			wantIntents: 0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := completion(t, tc.content)
			defer srv.Close()
			p := newPlanner(t, srv.URL+"/v1", nil)
			intents, err := p.Plan(context.Background(), planner.Request{
				Snapshots:   []contract.Snapshot{snap(1)},
				ServerNowMS: 1_700_000_000_000,
				IntentTTLMS: 30_000,
			})
			if err != nil {
				t.Fatalf("Plan: %v", err)
			}
			if len(intents) != tc.wantIntents {
				t.Fatalf("got %d intents, want %d (%s): %+v", len(intents), tc.wantIntents, tc.why, intents)
			}
			if tc.wantIntents == 0 {
				return
			}
			if intents[0].Kind != tc.wantKind {
				t.Errorf("kind = %q, want %q", intents[0].Kind, tc.wantKind)
			}
			if tc.wantPOI != "" && (intents[0].Travel == nil || intents[0].Travel.POIID != tc.wantPOI) {
				t.Errorf("poi = %+v, want %q", intents[0].Travel, tc.wantPOI)
			}
			if intents[0].Bot != (contract.BotID{Realm: 1, GUID: 1}) {
				t.Errorf("bot = %s; identity must come from what we sent, never from the model", intents[0].Bot)
			}
			if intents[0].Source != "llm" {
				t.Errorf("source = %q, want llm", intents[0].Source)
			}
			if intents[0].ExpiresAtMS != 1_700_000_030_000 {
				t.Errorf("expiry = %d, want the server clock plus TTL", intents[0].ExpiresAtMS)
			}
			if err := intents[0].Validate(); err != nil {
				t.Errorf("emitted an invalid intent: %v", err)
			}
		})
	}
}

func TestTransportFailures(t *testing.T) {
	tests := []struct {
		name    string
		handler http.HandlerFunc
		wantErr string
	}{
		{
			name: "429 is an error, not a retry",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = io.WriteString(w, `{"error":{"message":"slow down"}}`)
			},
			wantErr: "429",
		},
		{
			name: "500",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusInternalServerError)
			},
			wantErr: "500",
		},
		{
			name: "error object in a 200",
			handler: func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.WriteString(w, `{"error":{"message":"context length exceeded"}}`)
			},
			wantErr: "context length",
		},
		{
			name: "no choices",
			handler: func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.WriteString(w, `{"choices":[]}`)
			},
			wantErr: "no choices",
		},
		{
			name: "not json",
			handler: func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.WriteString(w, `<html>proxy error</html>`)
			},
			wantErr: "chat-completions JSON",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(tc.handler)
			defer srv.Close()
			p := newPlanner(t, srv.URL+"/v1", nil)
			_, err := p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{snap(1)}})
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("err = %v, want one containing %q", err, tc.wantErr)
			}
		})
	}
}

// A slow endpoint must surface as a context error so [planner.Fallback] can act
// on it, rather than as a hang.
func TestSlowEndpointRespectsContext(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer func() { close(release); srv.Close() }()

	p := newPlanner(t, srv.URL+"/v1", nil)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := p.Plan(ctx, planner.Request{Snapshots: []contract.Snapshot{snap(1)}})
	if err == nil {
		t.Fatal("expected an error from a slow endpoint")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want it to wrap context.DeadlineExceeded so Fallback can classify it", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("took %s; the context deadline should have bounded it", elapsed)
	}
}

// Repeated failures open the breaker so a dead endpoint stops costing every
// batch its full timeout.
func TestCircuitBreaker(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	p := newPlanner(t, srv.URL+"/v1", nil)

	if !p.Ready() {
		t.Fatal("a freshly constructed planner should start optimistic; a startup probe would make the model a startup dependency")
	}
	for i := 0; i < llm.FailureThreshold; i++ {
		_, _ = p.Plan(context.Background(), planner.Request{Snapshots: []contract.Snapshot{snap(1)}})
	}
	if p.Ready() {
		t.Fatalf("breaker did not open after %d consecutive failures", llm.FailureThreshold)
	}
	p.MarkHealthy()
	if !p.Ready() {
		t.Fatal("MarkHealthy did not reopen the breaker")
	}
}

// Batches larger than MaxBotsPerCall are truncated, not split. The remainder is
// the fallback planner's problem, which is the safe direction.
func TestBatchTruncation(t *testing.T) {
	srv := completion(t, `{"intents":[{"bot":0,"kind":"rest"},{"bot":1,"kind":"rest"},{"bot":2,"kind":"rest"}]}`)
	defer srv.Close()
	p := newPlanner(t, srv.URL+"/v1", func(c *llm.Config) { c.MaxBotsPerCall = 2 })

	batch := []contract.Snapshot{snap(1), snap(2), snap(3)}
	intents, err := p.Plan(context.Background(), planner.Request{Snapshots: batch})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(intents) != 2 {
		t.Fatalf("got %d intents, want 2 (the third bot is left to the fallback)", len(intents))
	}
	for _, in := range intents {
		if in.Bot.GUID == 3 {
			t.Fatal("an intent was produced for a bot outside the truncated batch")
		}
	}
}

func TestEmptyBatchIsNoOp(t *testing.T) {
	p := newPlanner(t, "http://127.0.0.1:1/v1", nil)
	intents, err := p.Plan(context.Background(), planner.Request{})
	if err != nil || len(intents) != 0 {
		t.Fatalf("empty batch: intents = %v, err = %v; want no call and no error", intents, err)
	}
}

func TestConfigRedaction(t *testing.T) {
	p := newPlanner(t, "http://x/v1", func(c *llm.Config) { c.APIKey = "sk-verysecret" })
	if got := p.Config().APIKey; got == "sk-verysecret" {
		t.Fatal("Config() returned the raw API key; it must be redacted before it can reach a log")
	}
}
