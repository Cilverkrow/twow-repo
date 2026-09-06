package llm

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func budgetCaller(t *testing.T, poc bool, cfg Config) func(context.Context) error {
	t.Helper()
	if poc {
		p, err := NewPoC(true, cfg, nil)
		if err != nil {
			t.Fatal(err)
		}
		return func(ctx context.Context) error { _, err := p.PlanOne(ctx, pocFixture()); return err }
	}
	p, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return func(ctx context.Context) error { _, err := p.Plan(ctx, pocFixture()); return err }
}

func budgetConfig(url string, b *TokenBudget) Config {
	return Config{Enabled: true, BaseURL: url, Model: "fixture", MaxTokens: 10, Timeout: time.Second, TokenBudget: b}
}

func TestTokenBudgetBothPathsAdmissionBoundaries(t *testing.T) {
	for _, poc := range []bool{false, true} {
		t.Run(map[bool]string{false: "planner", true: "poc"}[poc], func(t *testing.T) {
			var calls atomic.Int64
			var size atomic.Int64
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				raw, _ := io.ReadAll(r.Body)
				size.Store(int64(len(raw)))
				var body chatRequest
				if json.Unmarshal(raw, &body) != nil || body.MaxTokens != 10 {
					t.Error("output limit missing")
				}
				io.WriteString(w, envelope(goodProposal))
			}))
			defer s.Close()
			b := testBudget(t, TokenLimits{10000, 10, 10010, 20020}, nil)
			if err := budgetCaller(t, poc, budgetConfig(s.URL, b))(context.Background()); err != nil {
				t.Fatal(err)
			}
			n := size.Load()
			for _, limit := range []int64{n - 1, n, n + 1} {
				b := testBudget(t, TokenLimits{limit, 10, limit + 10, limit + 10}, nil)
				call := budgetCaller(t, poc, budgetConfig(s.URL, b))
				before := calls.Load()
				err := call(context.Background())
				if limit < n {
					if !errors.Is(err, ErrTokenBudget) || calls.Load() != before {
						t.Fatal("input rejection caused I/O", err)
					}
				} else {
					if err != nil || calls.Load() != before+1 {
						t.Fatal("boundary rejected", err)
					}
					if err = call(context.Background()); !errors.Is(err, ErrTokenBudget) || calls.Load() != before+1 {
						t.Fatal("window bypass", err)
					}
				}
			}
		})
	}
}

func TestTokenBudgetSharedAcrossBothPaths(t *testing.T) {
	var calls atomic.Int64
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); io.WriteString(w, envelope(goodProposal)) }))
	defer s.Close()
	b := testBudget(t, TokenLimits{10000, 10, 10010, 10010}, nil)
	regular := budgetCaller(t, false, budgetConfig(s.URL, b))
	poc := budgetCaller(t, true, budgetConfig(s.URL, b))
	if _, err := b.reserve(context.Background(), 10000, 10); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(regular(context.Background()), ErrTokenBudget) || !errors.Is(poc(context.Background()), ErrTokenBudget) || calls.Load() != 0 {
		t.Fatal("separate path bypassed shared budget")
	}
}

func TestTokenBudgetProviderFailuresStayCharged(t *testing.T) {
	for _, poc := range []bool{false, true} {
		for _, mode := range []string{"missing-usage", "low-usage", "bad-usage", "bad-usage-429", "429", "invalid-json", "redirect", "timeout"} {
			t.Run(map[bool]string{false: "planner", true: "poc"}[poc]+"/"+mode, func(t *testing.T) {
				var calls atomic.Int64
				release := make(chan struct{})
				s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls.Add(1)
					switch mode {
					case "429":
						w.WriteHeader(429)
					case "redirect":
						http.Redirect(w, r, "/other", 307)
					case "invalid-json":
						io.WriteString(w, "invalid")
					case "timeout":
						select {
						case <-r.Context().Done():
						case <-release:
						}
					case "low-usage", "bad-usage", "bad-usage-429":
						usage := `"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},`
						if strings.HasPrefix(mode, "bad-usage") {
							usage = `"usage":{"prompt_tokens":1,"completion_tokens":11,"total_tokens":12},`
						}
						if mode == "bad-usage-429" {
							w.WriteHeader(429)
						}
						io.WriteString(w, "{"+usage+envelope(goodProposal)[1:])
					default:
						io.WriteString(w, envelope(goodProposal))
					}
				}))
				defer s.Close()
				defer close(release)
				b := testBudget(t, TokenLimits{10000, 10, 10010, 10010}, nil)
				cfg := budgetConfig(s.URL, b)
				cfg.Timeout = 100 * time.Millisecond
				call := budgetCaller(t, poc, cfg)
				err := call(context.Background())
				if (mode == "missing-usage" || mode == "low-usage") && err != nil {
					t.Fatal(err)
				}
				if mode != "missing-usage" && mode != "low-usage" && err == nil {
					t.Fatal("bad provider accepted")
				}
				if calls.Load() != 1 || b.usedHour <= 10 || b.usedDay != b.usedHour {
					t.Fatal("request uncharged or duplicate")
				}
				if strings.HasPrefix(mode, "bad-usage") && !b.stopped {
					t.Fatal("usage overage did not latch")
				}
			})
		}
	}
}

func TestTokenBudgetOutputConfigAndUTF8(t *testing.T) {
	b := testBudget(t, TokenLimits{1, 10, 11, 11}, nil)
	for _, max := range []int{-1, 11} {
		cfg := budgetConfig("http://unused.invalid", b)
		cfg.MaxTokens = max
		if _, err := New(cfg); err == nil {
			t.Fatal("bad output cap accepted")
		}
	}
	p, err := New(budgetConfig("http://unused.invalid", b))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p.reserveTokens(context.Background(), []byte("é")); err == nil {
		t.Fatal("counted characters, not serialized bytes")
	}
	if _, err := p.reserveTokens(context.Background(), []byte{0xff}); err == nil {
		t.Fatal("invalid UTF8 admitted")
	}
	if b.usedDay != 0 {
		t.Fatal("rejection charged")
	}
}

func TestTokenBudgetCancelledBeforeProvider(t *testing.T) {
	for _, poc := range []bool{false, true} {
		b := testBudget(t, TokenLimits{10000, 10, 10010, 10010}, nil)
		s := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("I/O after cancellation") }))
		call := budgetCaller(t, poc, budgetConfig(s.URL, b))
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if err := call(ctx); err == nil {
			t.Fatal("cancellation accepted")
		}
		if b.usedDay != 0 {
			t.Fatal("pre-admission cancellation charged")
		}
		s.Close()
	}
}

func TestTokenBudgetUsageEnvelopeDoesNotPermitOtherFields(t *testing.T) {
	valid := `{"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},` + envelope(goodProposal)[1:]
	if _, err := pocContent([]byte(valid)); err != nil {
		t.Fatal(err)
	}
	if _, err := pocContent([]byte(strings.Replace(valid, `"usage":`, `"other":`, 1))); err == nil {
		t.Fatal("unknown envelope field admitted")
	}
}

func TestTokenBudgetDuplicateUsageLatchesBothPaths(t *testing.T) {
	const high = `{"prompt_tokens":999999,"completion_tokens":1,"total_tokens":1000000}`
	const low = `{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}`
	for _, poc := range []bool{false, true} {
		for _, status := range []int{200, 429} {
			for _, pair := range []string{high + `,"usage":null`, high + `,"usage":` + low, `null,"usage":` + high, low + `,"usage":` + high, `null,"usage":null`, low + `,"us\u0061ge":` + low} {
				t.Run(fmt.Sprintf("poc=%t/status=%d/case=%d", poc, status, len(pair)), func(t *testing.T) {
					var calls atomic.Int64
					s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						calls.Add(1)
						w.WriteHeader(status)
						io.WriteString(w, `{"usage":`+pair+`,`+envelope(goodProposal)[1:])
					}))
					defer s.Close()
					b := testBudget(t, TokenLimits{10000, 10, 1000000, 1000000}, nil)
					first := budgetCaller(t, poc, budgetConfig(s.URL, b))
					if err := first(context.Background()); !errors.Is(err, ErrTokenUsage) {
						t.Error("ambiguous usage not rejected with accounting error")
					}
					charge := b.usedDay
					if !b.stopped || charge <= 10 || b.usedHour != charge {
						t.Errorf("missing permanent latch or reservation")
					}
					for _, nextPoC := range []bool{poc, !poc} {
						if err := budgetCaller(t, nextPoC, budgetConfig(s.URL, b))(context.Background()); !errors.Is(err, ErrTokenBudget) {
							t.Errorf("shared-path admission remained open")
						}
					}
					if calls.Load() != 1 || b.usedDay != charge || b.usedHour != charge {
						t.Error("additional provider I/O or changed reservation")
					}
				})
			}
		}
	}
}

func TestAccountingUsagePreservesExtensionsAndNullPolicy(t *testing.T) {
	for _, raw := range []string{`{}`, `{"usage":null}`, `{"extension":{"usage":null},"usage":null}`, `{"extension":1,"extension":2}`, `invalid`} {
		b := testBudget(t, TokenLimits{10, 5, 30, 30}, nil)
		r, _ := b.reserve(context.Background(), 10, 5)
		if r.observeUsage([]byte(raw)) != nil || b.stopped || b.usedDay != 15 {
			t.Fatal("changed non-ambiguous accounting policy")
		}
	}
}
