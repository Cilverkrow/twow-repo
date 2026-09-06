package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"sync"
	"time"
	"unicode/utf8"
)

// TokenLimits bounds local accounting units, NOT a provider's bill. Input
// units are UTF-8 bytes of the serialized chat request (an intentionally coarse
// estimate, not an exact tokenizer). Output units reserve max_tokens in full.
type TokenLimits struct {
	InputPerRequest  int64
	OutputPerRequest int64
	PerHour          int64
	PerDay           int64
}

func DefaultTokenLimits() TokenLimits {
	return TokenLimits{InputPerRequest: 32768, OutputPerRequest: 1024, PerHour: 262144, PerDay: 1048576}
}

func (l TokenLimits) validate() error {
	if l.InputPerRequest <= 0 || l.OutputPerRequest <= 0 || l.PerHour <= 0 || l.PerDay <= 0 || l.InputPerRequest > math.MaxInt64-l.OutputPerRequest || l.InputPerRequest+l.OutputPerRequest > l.PerHour || l.PerHour > l.PerDay {
		return errors.New("llm: invalid token budget limits")
	}
	return nil
}

var ErrTokenBudget = errors.New("llm: token budget admission denied")
var ErrTokenUsage = errors.New("llm: inconsistent provider token usage")

// TokenBudget is shared by every Planner/PoC given this pointer. It is local
// memory, not durable or cluster-wide. Windows are fixed 1h/24h intervals since
// construction, using time.Now's monotonic component, NOT UTC calendar buckets.
// Constructing another budget or restarting creates a NEW budget; callers must
// not do that per request. No refill/reset/enable API exists.
type TokenBudget struct {
	mu                sync.Mutex
	limits            TokenLimits
	clock             func() time.Time
	epoch             time.Time
	highWater         time.Duration
	hour, day         int64
	usedHour, usedDay int64
	stopped           bool
}

func NewTokenBudget(limits TokenLimits, clock func() time.Time) (*TokenBudget, error) {
	if err := limits.validate(); err != nil {
		return nil, err
	}
	if clock == nil {
		clock = time.Now
	}
	return &TokenBudget{limits: limits, clock: clock, epoch: clock()}, nil
}

// Limits is an immutable policy copy; it contains no counters or identifiers.
func (b *TokenBudget) Limits() TokenLimits { return b.limits }

// Stop permanently closes admission on this budget, including both call paths
// when they share it. It cannot recall provider requests already admitted.
func (b *TokenBudget) Stop() { b.mu.Lock(); b.stopped = true; b.mu.Unlock() }

var defaultTokenBudget = func() *TokenBudget {
	b, err := NewTokenBudget(DefaultTokenLimits(), nil)
	if err != nil {
		panic(err)
	} // compile-time defaults must be valid
	return b
}()

type tokenReservation struct {
	budget        *TokenBudget
	input, output int64
}

func (b *TokenBudget) reserve(ctx context.Context, input, output int64) (*tokenReservation, error) {
	if b == nil || b.clock == nil {
		return nil, ErrTokenBudget
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if b.stopped || input <= 0 || output <= 0 || input > b.limits.InputPerRequest || output > b.limits.OutputPerRequest || input > math.MaxInt64-output {
		return nil, ErrTokenBudget
	}
	elapsed := b.clock().Sub(b.epoch)
	if elapsed < 0 || elapsed < b.highWater {
		return nil, ErrTokenBudget
	}
	b.highWater = elapsed
	hour, day := int64(elapsed/time.Hour), int64(elapsed/(24*time.Hour))
	if hour > b.hour {
		b.hour = hour
		b.usedHour = 0
	}
	if day > b.day {
		b.day = day
		b.usedDay = 0
	}
	charge := input + output
	// Subtraction rather than unchecked addition also makes overflow fail closed.
	if charge > b.limits.PerHour-b.usedHour || charge > b.limits.PerDay-b.usedDay {
		return nil, ErrTokenBudget
	}
	b.usedHour += charge
	b.usedDay += charge
	return &tokenReservation{budget: b, input: input, output: output}, nil
}

func (p *Planner) reserveTokens(ctx context.Context, body []byte) (*tokenReservation, error) {
	if !utf8.Valid(body) {
		return nil, ErrTokenBudget
	}
	return p.cfg.TokenBudget.reserve(ctx, int64(len(body)), int64(p.cfg.MaxTokens))
}

// usageObject decodes a provider's `usage` object: strict about the accounting
// triple, tolerant of everything else.
//
// It replaces a call to exactObject with an empty optional list, which rejected
// ANY key it had not been told about. Every mainstream OpenAI-compatible
// provider now returns prompt_tokens_details and completion_tokens_details
// inside usage, so the first ordinary 200 OK failed validation and the caller
// latched the budget -- process-wide, with no reset, for the life of the
// process. A provider adding a field became a permanent outage.
//
// Listing today's extra keys as optional would have fixed today's providers and
// re-broken on the next one. An unrecognised key is not evidence about the
// numbers, so it is skipped. The three accounting fields keep exactObject's full
// strictness -- no duplicates, no nulls, no wrong types, all three required --
// because those ARE the evidence, and disagreement there is what the latch is
// for.
func usageObject(raw []byte) (map[string]json.RawMessage, error) {
	if !utf8.Valid(raw) {
		return nil, errors.New("poc: invalid UTF-8")
	}
	required := []string{"prompt_tokens", "completion_tokens", "total_tokens"}
	want := make(map[string]bool, len(required))
	for _, k := range required {
		want[k] = true
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	t, err := d.Token()
	if err != nil || t != json.Delim('{') {
		return nil, errors.New("poc: expected object")
	}
	fields := make(map[string]json.RawMessage)
	for d.More() {
		t, err := d.Token()
		if err != nil {
			return nil, err
		}
		k, ok := t.(string)
		if !ok {
			return nil, errors.New("poc: invalid field")
		}
		var value json.RawMessage
		if err := d.Decode(&value); err != nil {
			return nil, err
		}
		// Skipped AFTER decoding, so the value is still consumed and a
		// malformed one is still a parse error.
		if !want[k] {
			continue
		}
		if fields[k] != nil {
			return nil, errors.New("poc: invalid field")
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, errors.New("poc: null field")
		}
		fields[k] = value
	}
	if _, err := d.Token(); err != nil {
		return nil, err
	}
	if _, err := d.Token(); err != io.EOF {
		return nil, errors.New("poc: trailing content")
	}
	for _, k := range required {
		if fields[k] == nil {
			return nil, errors.New("poc: missing field")
		}
	}
	return fields, nil
}

// observeUsage NEVER refunds. Missing/null usage, cancellation, HTTP failure,
// decoding failure and uncertain execution all retain the complete reservation.
// If usage is supplied, require a consistent integer triple. Any contradictory
// evidence closes this budget, even if this reservation belongs to an old window.
// No raw provider error or usage content is returned in the error message.
func (r *tokenReservation) observeUsage(raw []byte) error {
	usage, err := accountingUsage(raw)
	if err != nil {
		r.budget.Stop()
		return ErrTokenUsage
	}
	if len(usage) == 0 || bytes.Equal(bytes.TrimSpace(usage), []byte("null")) {
		return nil
	}
	fields, err := usageObject(usage)
	var input, output, total int64
	if err != nil || json.Unmarshal(fields["prompt_tokens"], &input) != nil || json.Unmarshal(fields["completion_tokens"], &output) != nil || json.Unmarshal(fields["total_tokens"], &total) != nil || input < 0 || output < 0 || input > math.MaxInt64-output || total != input+output || input > r.input || output > r.output {
		r.budget.Stop()
		return ErrTokenUsage
	}
	return nil
}

// Inspect root keys before any map conversion can collapse duplicates. Only
// usage belongs to this accounting projection; regular provider extensions
// remain the responsibility of the caller's decoder. Malformed JSON retains
// the existing caller-decoder policy; ambiguous usage latches closed.
func accountingUsage(raw []byte) (json.RawMessage, error) {
	if !json.Valid(raw) {
		return nil, nil // caller rejects it; reservation is never refunded
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	if token, err := d.Token(); err != nil || token != json.Delim('{') {
		return nil, nil // preserve non-object response decoding policy
	}
	var usage json.RawMessage
	seen := false
	for d.More() {
		token, err := d.Token()
		if err != nil {
			return nil, ErrTokenUsage
		}
		key, ok := token.(string)
		if !ok || (key == "usage" && seen) {
			return nil, ErrTokenUsage
		}
		var value json.RawMessage
		if d.Decode(&value) != nil {
			return nil, ErrTokenUsage
		}
		if key == "usage" {
			seen = true
			usage = value
		}
	}
	if token, err := d.Token(); err != nil || token != json.Delim('}') {
		return nil, ErrTokenUsage
	}
	if _, err := d.Token(); err != io.EOF {
		return nil, ErrTokenUsage
	}
	return usage, nil
}
