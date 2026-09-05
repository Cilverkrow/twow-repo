// Package llm is the OpenAI-compatible planner.
//
// SKELETON. Read this before designing against it:
//
// What is real here: the configuration surface, the provider auth adapters, the
// request construction, the response parsing, the strict validation of what the
// model proposes, the timeout, and the refusal to ever be a hard dependency.
// All of that is exercised by tests against an httptest server.
//
// What is NOT real: the prompt is a first draft and has had no evaluation; the
// model is asked for JSON and trusted only as far as [validate] allows; there is
// no batching strategy beyond "one call per batch"; token accounting is local
// and estimated (TOKEN-BUDGET.md), not a metered-endpoint guarantee. Cost caps
// and rate-limit handling are still separate ARCH-003 prerequisites.
//
// # Why OpenAI-compatible rather than a provider SDK
//
// ARCH-003 decides one client with per-provider adapters for auth and quirks.
// vLLM (the self-hosted default), llama.cpp, Ollama, OpenAI, Azure OpenAI,
// Groq, Together and OpenRouter all speak the chat-completions shape. Anthropic
// does not natively, but is reachable through an OpenAI-compatible gateway, and
// the [ProviderAnthropic] adapter exists for gateways that want Anthropic's
// header names. Swapping backends is configuration, not code, and never a C++
// rebuild.
//
// # Egress
//
// Everything this package sends leaves the machine when the endpoint is a cloud
// provider. [redact] is the single place that decides what may go, and it sends
// no GUIDs, no realm ids, no account data and no character names. Bots are
// referred to by their index within the batch. This is deliberately stricter
// than ARCH-003 requires, because loosening a filter is a reviewable change and
// tightening one after a leak is not.
package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
)

// Provider selects the auth and header quirks for a backend. The request body
// is the same for all of them.
type Provider string

const (
	// ProviderOpenAI covers OpenAI itself and everything that copied its auth:
	// vLLM, llama.cpp server, Ollama, Groq, Together, OpenRouter. Bearer token,
	// or no token at all for a local endpoint.
	ProviderOpenAI Provider = "openai"
	// ProviderAzure uses the api-key header and expects the deployment name in
	// the URL rather than the model in the body.
	ProviderAzure Provider = "azure"
	// ProviderAnthropic uses x-api-key plus anthropic-version. Point this at an
	// OpenAI-compatible Anthropic gateway; the body shape stays chat-completions.
	ProviderAnthropic Provider = "anthropic"
)

// AnthropicVersion is the version header value sent for [ProviderAnthropic].
const AnthropicVersion = "2023-06-01"

// Config is the whole backend surface. Everything here comes from environment
// or a config file; nothing is compiled in. That is the direct fix for the
// ARCH-003 finding that the model was a compile-time constant
// (kModel = "qwen2.5:7b" in ExternalLLMBridgeService.cpp).
type Config struct {
	// Enabled gates the planner entirely. Default false: a fresh deployment
	// plans with rules only until somebody deliberately turns inference on.
	Enabled bool
	// BaseURL is the endpoint root, e.g. "http://vllm:8000/v1" or
	// "https://api.openai.com/v1". The path "/chat/completions" is appended.
	BaseURL string
	// Model is the model name sent in the body. For Azure this is the
	// deployment name and also goes in the URL.
	Model string
	// APIKey is the credential. Empty is valid and normal for a local vLLM or
	// llama.cpp endpoint. It must arrive from a secret mechanism (compose .env,
	// Helm existingSecret) and must never be written to a rendered .conf or to
	// Git (ADR-0024 invariant 5). It is never logged, and [Config.Redacted]
	// exists so a config dump cannot leak it by accident.
	APIKey string
	// Provider selects auth quirks. Empty means [ProviderOpenAI].
	Provider Provider
	// Timeout bounds one call end to end. This is the number that decides how
	// long a batch waits before the rule planner answers instead. It should be
	// well under the worldserver's own planning cadence.
	Timeout time.Duration
	// MaxTokens caps the completion. A hard cap matters more than usual here:
	// the response is parsed as JSON, and a truncated JSON document is a failed
	// batch, so this must be generous enough for the batch size being sent.
	MaxTokens int
	// Temperature. 0 for reproducibility, which is what you want while the
	// prompt is still being evaluated.
	Temperature float64
	// MaxBotsPerCall caps how many bots go into one model call. Larger
	// amortises the round trip; too large and the model loses track. Batches
	// bigger than this are truncated rather than split, and the remainder falls
	// through to the rule planner, which is the safe direction.
	MaxBotsPerCall int
	// AllowedModels, when non-empty, is an allowlist checked at construction.
	// ARCH-003 asks for this so a typo in configuration cannot silently switch
	// a production realm onto a different or more expensive model.
	AllowedModels []string
	// HTTPClient allows tests to inject a transport. Nil means a client built
	// from Timeout.
	HTTPClient *http.Client
	// TokenBudget is shared local admission state. Nil uses a finite process-
	// shared default, never unlimited. Share the same pointer between custom
	// planners and PoCs; constructing one per request defeats window limits.
	TokenBudget *TokenBudget `json:"-"`
}

// Redacted returns a copy safe to log.
func (c Config) Redacted() Config {
	if c.APIKey != "" {
		c.APIKey = "***"
	}
	c.TokenBudget = nil // do not serialize mutable accounting internals
	return c
}

// ErrDisabled is returned by [New] when the config is not enabled.
var ErrDisabled = errors.New("llm planner disabled")

// Planner is the OpenAI-compatible planner.
type Planner struct {
	cfg    Config
	client *http.Client
	// healthy tracks whether the last call succeeded. It is advisory: it feeds
	// Ready so that a persistently broken endpoint stops being tried on every
	// batch, but it never makes the *service* unready, because the rule planner
	// still works.
	healthy atomic.Bool
	// consecutiveFailures drives a crude circuit breaker.
	consecutiveFailures atomic.Int64
}

// FailureThreshold is how many consecutive failures open the breaker. Once
// open, Ready reports false and [planner.Fallback] skips the primary entirely,
// which stops a dead endpoint from costing every batch its full timeout.
const FailureThreshold = 5

// New validates config and builds the planner. It performs no I/O: constructing
// a planner must never depend on the model being up, or a restart during an
// inference outage would fail to start a service that is designed to work
// without inference.
func New(cfg Config) (*Planner, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if cfg.BaseURL == "" {
		return nil, errors.New("llm: base URL is required when the LLM planner is enabled")
	}
	if cfg.Model == "" {
		return nil, errors.New("llm: model is required when the LLM planner is enabled")
	}
	if len(cfg.AllowedModels) > 0 {
		ok := false
		for _, m := range cfg.AllowedModels {
			if m == cfg.Model {
				ok = true
				break
			}
		}
		if !ok {
			return nil, fmt.Errorf("llm: model %q is not in the allowlist %v", cfg.Model, cfg.AllowedModels)
		}
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 3 * time.Second
	}
	if cfg.MaxTokens < 0 {
		return nil, errors.New("llm: max_tokens must not be negative")
	}
	if cfg.MaxTokens == 0 {
		cfg.MaxTokens = 1024
	}
	if cfg.TokenBudget == nil {
		cfg.TokenBudget = defaultTokenBudget
	}
	if cfg.TokenBudget.limits.validate() != nil || int64(cfg.MaxTokens) > cfg.TokenBudget.limits.OutputPerRequest {
		return nil, errors.New("llm: max_tokens exceeds token budget or budget is invalid")
	}
	if cfg.MaxBotsPerCall <= 0 {
		cfg.MaxBotsPerCall = 16
	}
	if cfg.Provider == "" {
		cfg.Provider = ProviderOpenAI
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: cfg.Timeout}
	}
	p := &Planner{cfg: cfg, client: client}
	// Start optimistic. A first-call failure opens the breaker soon enough, and
	// starting pessimistic would require a startup probe, which would make the
	// model a startup dependency.
	p.healthy.Store(true)
	return p, nil
}

func (p *Planner) Name() string { return "llm" }

// Ready reports whether the breaker is closed. It does no I/O.
func (p *Planner) Ready() bool { return p.healthy.Load() }

// Config returns the redacted config, for the /v1/contract and log surfaces.
func (p *Planner) Config() Config { return p.cfg.Redacted() }

// chat request/response, the OpenAI chat-completions shape.
type chatRequest struct {
	Model       string        `json:"model"`
	Messages    []chatMessage `json:"messages"`
	MaxTokens   int           `json:"max_tokens"`
	Temperature float64       `json:"temperature"`
	Stream      bool          `json:"stream"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatResponse struct {
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error,omitempty"`
}

// modelIntent is the shape the model is asked to emit. It is deliberately not
// [contract.Intent]: the model is never allowed to name a bot identity. It
// names a batch index, and this package maps that index back to a BotID it
// already knows. A model that hallucinates a GUID therefore cannot address a
// bot, which is the structural half of ADR-0024 invariant 1.
type modelIntent struct {
	Bot       int     `json:"bot"`
	Kind      string  `json:"kind"`
	POIID     string  `json:"poi_id,omitempty"`
	QuestID   uint32  `json:"quest_id,omitempty"`
	Why       string  `json:"why,omitempty"`
	Certainty float64 `json:"certainty,omitempty"`
}

type modelReply struct {
	Intents []modelIntent `json:"intents"`
}

// Plan asks the model for intents.
//
// Everything the model returns is treated as untrusted input: unknown kinds are
// dropped, POI ids that were not in that bot's snapshot are dropped, and bot
// indices out of range are dropped. Whatever survives is returned; whatever does
// not is simply absent, and [planner.Fallback] covers those bots with the rule
// planner. There is no path here that produces a wrong intent rather than no
// intent.
func (p *Planner) Plan(ctx context.Context, req planner.Request) ([]contract.Intent, error) {
	if len(req.Snapshots) == 0 {
		return nil, nil
	}
	batch := req.Snapshots
	if len(batch) > p.cfg.MaxBotsPerCall {
		// Truncate rather than split. The remainder falls to the rule planner,
		// which is a worse plan but a guaranteed one; splitting would multiply
		// the round trips this batching design exists to avoid.
		batch = batch[:p.cfg.MaxBotsPerCall]
	}

	body, err := json.Marshal(chatRequest{
		Model:       p.cfg.Model,
		Messages:    p.buildMessages(batch),
		MaxTokens:   p.cfg.MaxTokens,
		Temperature: p.cfg.Temperature,
	})
	if err != nil {
		return nil, fmt.Errorf("llm: encoding request: %w", err)
	}

	url := strings.TrimSuffix(p.cfg.BaseURL, "/") + "/chat/completions"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("llm: building request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	p.applyAuth(httpReq)
	reservation, err := p.reserveTokens(ctx, body)
	if err != nil {
		return nil, err
	}

	// One admitted destination: redirects are not another budgeted call.
	client := *p.client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := client.Do(httpReq)
	if err != nil {
		p.recordFailure()
		return nil, fmt.Errorf("llm: %w", err)
	}
	defer resp.Body.Close()

	// Cap the read. A misconfigured endpoint returning a huge body must not be
	// able to exhaust memory in a service that is holding 1000 bots' snapshots.
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		p.recordFailure()
		return nil, fmt.Errorf("llm: reading response: %w", err)
	}
	if err := reservation.observeUsage(raw); err != nil {
		p.recordFailure()
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		p.recordFailure()
		// 429 and 5xx are the retryable cloud cases ARCH-003 flags. There is no
		// retry here on purpose: a retry inside the planner would eat the
		// fallback budget. Retry, if it is ever wanted, belongs above the
		// timeout, not below it.
		return nil, fmt.Errorf("llm: endpoint returned %d: %s", resp.StatusCode, truncate(string(raw), 200))
	}

	var cr chatResponse
	if err := json.Unmarshal(raw, &cr); err != nil {
		p.recordFailure()
		return nil, fmt.Errorf("llm: response is not chat-completions JSON: %w", err)
	}
	if cr.Error != nil {
		p.recordFailure()
		return nil, fmt.Errorf("llm: endpoint error: %s", cr.Error.Message)
	}
	if len(cr.Choices) == 0 {
		p.recordFailure()
		return nil, errors.New("llm: response had no choices")
	}

	p.recordSuccess()
	return p.parseIntents(cr.Choices[0].Message.Content, batch, req.ExpiryMS()), nil
}

func (p *Planner) applyAuth(r *http.Request) {
	switch p.cfg.Provider {
	case ProviderAzure:
		if p.cfg.APIKey != "" {
			r.Header.Set("api-key", p.cfg.APIKey)
		}
	case ProviderAnthropic:
		if p.cfg.APIKey != "" {
			r.Header.Set("x-api-key", p.cfg.APIKey)
		}
		r.Header.Set("anthropic-version", AnthropicVersion)
	default:
		// Local backends (vLLM, llama.cpp, Ollama) usually need no key at all,
		// so an empty key must not become a literal "Bearer " header.
		if p.cfg.APIKey != "" {
			r.Header.Set("Authorization", "Bearer "+p.cfg.APIKey)
		}
	}
}

func (p *Planner) recordFailure() {
	if p.consecutiveFailures.Add(1) >= FailureThreshold {
		p.healthy.Store(false)
	}
}

func (p *Planner) recordSuccess() {
	p.consecutiveFailures.Store(0)
	p.healthy.Store(true)
}

// MarkHealthy closes the breaker again. The service calls this on a slow timer
// so a recovered endpoint comes back without a restart.
func (p *Planner) MarkHealthy() {
	p.consecutiveFailures.Store(0)
	p.healthy.Store(true)
}

const systemPrompt = `You plan slow, coarse goals for automated characters in a fantasy MMO.
You are given a numbered list of characters and, for each, a list of candidate destinations with ids.
Reply with JSON only, no prose, in this exact shape:
{"intents":[{"bot":0,"kind":"travel_to","poi_id":"p1","certainty":0.7,"why":"short reason"}]}
Allowed kinds: idle, travel_to, pick_quest, turn_in_quest, abandon_quest, grind_area, vendor_sell, repair, rest.
Rules you must not break:
- poi_id must be one of the ids listed for that same character. Never invent an id.
- "bot" must be an index from the list you were given.
- Prefer "idle" when nothing listed is clearly worthwhile. "idle" is always acceptable.
- You have no authority over who a character is. Never suggest removing, replacing or logging out a character.`

// buildMessages renders the prompt. This is a first draft with no evaluation
// behind it; treat it as a placeholder that proves the plumbing.
func (p *Planner) buildMessages(batch []contract.Snapshot) []chatMessage {
	var sb strings.Builder
	for i := range batch {
		sb.WriteString(redact(i, &batch[i]))
		sb.WriteByte('\n')
	}
	return []chatMessage{
		{Role: "system", Content: systemPrompt},
		{Role: "user", Content: sb.String()},
	}
}

// redact renders one snapshot for the model.
//
// This is the egress filter and the only place that decides what leaves the
// machine. It sends no GUID, no realm, no character name, no account data and
// no coordinates precise enough to be an identifier. The bot is an index.
//
// ARCH-003 asks for this to be a hard filter at the boundary rather than a
// prompt instruction, and this is that filter.
func redact(index int, s *contract.Snapshot) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "character %d: level %d class %d faction %s, health %.0f%%",
		index, s.Char.Level, s.Char.Class, s.Char.Faction, s.Vit.HealthPct)
	if s.Vit.DurabilityPct != nil {
		fmt.Fprintf(&sb, ", gear %.0f%%", *s.Vit.DurabilityPct)
	}
	fmt.Fprintf(&sb, ", %d free bag slots", s.Char.FreeBagSlots)
	if s.Vit.IsResting {
		sb.WriteString(", resting")
	}
	if len(s.Char.TraitKeys) > 0 {
		fmt.Fprintf(&sb, ", traits %s", strings.Join(s.Char.TraitKeys, "/"))
	}
	if len(s.Quests) > 0 {
		sb.WriteString("\n  quests:")
		for _, q := range s.Quests {
			fmt.Fprintf(&sb, " [%d %s %d/%d]", q.QuestID, q.Status, q.ObjectivesDone, q.ObjectivesTotal)
		}
	}
	if len(s.POIs) > 0 {
		sb.WriteString("\n  destinations:")
		for _, poi := range s.POIs {
			fmt.Fprintf(&sb, " [%s %s", poi.ID, poi.Kind)
			if poi.DistanceYards != nil {
				fmt.Fprintf(&sb, " %.0fy", *poi.DistanceYards)
			}
			sb.WriteByte(']')
		}
	} else {
		sb.WriteString("\n  destinations: none")
	}
	return sb.String()
}

// parseIntents turns the model's reply into validated intents.
func (p *Planner) parseIntents(content string, batch []contract.Snapshot, expiry int64) []contract.Intent {
	jsonText := extractJSON(content)
	if jsonText == "" {
		return nil
	}
	var reply modelReply
	if err := json.Unmarshal([]byte(jsonText), &reply); err != nil {
		return nil
	}
	seen := make(map[int]bool, len(reply.Intents))
	out := make([]contract.Intent, 0, len(reply.Intents))
	for _, mi := range reply.Intents {
		if mi.Bot < 0 || mi.Bot >= len(batch) || seen[mi.Bot] {
			continue
		}
		in, ok := validate(mi, &batch[mi.Bot])
		if !ok {
			continue
		}
		in.ExpiresAtMS = expiry
		if err := in.Validate(); err != nil {
			continue
		}
		seen[mi.Bot] = true
		out = append(out, in)
	}
	return out
}

// validate converts one model suggestion, rejecting anything the model was not
// entitled to say. It is the security boundary of this package: everything past
// it is treated as trusted, so everything before it must be checked.
func validate(mi modelIntent, s *contract.Snapshot) (contract.Intent, bool) {
	kind := contract.IntentKind(strings.TrimSpace(strings.ToLower(mi.Kind)))
	if !kind.IsKnown() {
		return contract.Intent{}, false
	}
	certainty := mi.Certainty
	if certainty < 0 || certainty > 1 {
		certainty = 0.5
	}
	in := contract.Intent{
		Bot:        s.Bot, // never from the model; always from what we sent.
		IntentID:   planner.NewIntentID(),
		Kind:       kind,
		Confidence: certainty,
		Source:     "llm",
		Rationale:  truncate("llm: "+mi.Why, contract.MaxRationaleBytes),
	}
	switch kind {
	case contract.IntentIdle, contract.IntentRest:
		return in, true
	case contract.IntentAbandonQuest:
		for _, q := range s.Quests {
			if q.QuestID == mi.QuestID {
				in.Quest = &contract.QuestParams{QuestID: mi.QuestID}
				return in, true
			}
		}
		return contract.Intent{}, false
	default:
		// POI-directed. The id must be one this bot was actually offered.
		for i := range s.POIs {
			if s.POIs[i].ID == mi.POIID && mi.POIID != "" {
				in.Travel = &contract.TravelParams{POIID: mi.POIID}
				if s.POIs[i].RelatedQuestID != 0 {
					in.Quest = &contract.QuestParams{QuestID: s.POIs[i].RelatedQuestID}
				}
				return in, true
			}
		}
		return contract.Intent{}, false
	}
}

// extractJSON pulls the first balanced JSON object out of a completion. Models
// wrap JSON in prose and in code fences no matter how firmly they are asked not
// to, and a parser that only accepts a bare object fails constantly for a
// reason that has nothing to do with the plan being wrong.
func extractJSON(s string) string {
	start := strings.Index(s, "{")
	if start < 0 {
		return ""
	}
	depth := 0
	inString := false
	escaped := false
	for i := start; i < len(s); i++ {
		c := s[i]
		if inString {
			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == '"':
				inString = false
			}
			continue
		}
		switch c {
		case '"':
			inString = true
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return s[start : i+1]
			}
		}
	}
	return ""
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
