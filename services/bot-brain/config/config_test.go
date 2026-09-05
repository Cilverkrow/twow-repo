package config_test

import (
	"strings"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/config"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/llm"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestDefaultsProduceAWorkingRulesOnlyService(t *testing.T) {
	cfg, err := config.Load(env(nil))
	if err != nil {
		t.Fatalf("defaults did not load: %v", err)
	}
	if cfg.LLM.Enabled {
		t.Error("inference is on by default; a fresh deployment must plan with rules until somebody turns it on")
	}
	if cfg.ListenAddr == "" || cfg.MaxBatch <= 0 || cfg.IntentTTL <= 0 {
		t.Errorf("defaults are not usable: %+v", cfg)
	}
	if cfg.LLM.TokenBudget == nil || cfg.LLM.TokenBudget.Limits() != llm.DefaultTokenLimits() {
		t.Fatal("default token budget missing")
	}
}

func TestTokenBudgetConfiguration(t *testing.T) {
	for _, key := range []string{"BOT_BRAIN_LLM_INPUT_TOKEN_BUDGET", "BOT_BRAIN_LLM_OUTPUT_TOKEN_BUDGET", "BOT_BRAIN_LLM_HOURLY_TOKEN_BUDGET", "BOT_BRAIN_LLM_DAILY_TOKEN_BUDGET", "BOT_BRAIN_LLM_MAX_TOKENS"} {
		for _, value := range []string{"0", "-1", "garbage", "9223372036854775808"} {
			if _, err := config.Load(env(map[string]string{key: value})); err == nil {
				t.Errorf("accepted %s=%s", key, value)
			}
		}
	}
	if _, err := config.Load(env(map[string]string{"BOT_BRAIN_LLM_MAX_TOKENS": "1025"})); err == nil {
		t.Fatal("output ceiling not enforced")
	}
	c, err := config.Load(env(map[string]string{"BOT_BRAIN_LLM_OUTPUT_TOKEN_BUDGET": "2048", "BOT_BRAIN_LLM_MAX_TOKENS": "2048"}))
	if err != nil || c.LLM.TokenBudget.Limits().OutputPerRequest != 2048 || c.LLM.Enabled {
		t.Fatal("explicit limit config", err)
	}
}

func TestLoad(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		check   func(*testing.T, config.Config)
		wantErr string
	}{
		{
			name: "durations accept go syntax",
			env:  map[string]string{"BOT_BRAIN_INTENT_TTL": "45s"},
			check: func(t *testing.T, c config.Config) {
				if c.IntentTTL != 45*time.Second {
					t.Errorf("ttl = %s, want 45s", c.IntentTTL)
				}
			},
		},
		{
			name: "bare integers are milliseconds",
			env:  map[string]string{"BOT_BRAIN_INTENT_TTL": "1500"},
			check: func(t *testing.T, c config.Config) {
				if c.IntentTTL != 1500*time.Millisecond {
					t.Errorf("ttl = %s, want 1.5s", c.IntentTTL)
				}
			},
		},
		{
			// This case previously asserted the opposite - that garbage fell
			// back to the default "rather than failing to start" - and it was
			// reversed deliberately.
			//
			// Failing to start is the SAFE outcome here, not the risky one.
			// ADR-0012 requires that normal bot AI continues whenever the
			// planning path is unavailable, so a brain that refuses to boot
			// costs bots their planner and nothing else: the worldserver runs
			// on, bots use the stock chooser, and the operator gets a loud
			// reason. Silently running on a default the operator did not choose
			// is the outcome with no signal attached to it.
			//
			// Note the package doc's promise is about UNSET values, which still
			// hold: an empty environment produces a working service.
			name:    "a value that is set but unreadable fails startup",
			env:     map[string]string{"BOT_BRAIN_INTENT_TTL": "soon"},
			wantErr: "BOT_BRAIN_INTENT_TTL",
		},
		{
			name: "vllm backend",
			env: map[string]string{
				"BOT_BRAIN_LLM_ENABLED":  "true",
				"BOT_BRAIN_LLM_BASE_URL": "http://vllm:8000/v1",
				"BOT_BRAIN_LLM_MODEL":    "qwen2.5-7b-instruct",
				"BOT_BRAIN_LLM_TIMEOUT":  "800ms",
			},
			check: func(t *testing.T, c config.Config) {
				if !c.LLM.Enabled || c.LLM.Model != "qwen2.5-7b-instruct" {
					t.Errorf("llm config = %+v", c.LLM.Redacted())
				}
				if c.LLM.Provider != llm.ProviderOpenAI {
					t.Errorf("provider = %q, want the openai-compatible default", c.LLM.Provider)
				}
			},
		},
		{
			name: "cloud backend with a key and an allowlist",
			env: map[string]string{
				"BOT_BRAIN_LLM_ENABLED":        "true",
				"BOT_BRAIN_LLM_BASE_URL":       "https://api.openai.com/v1",
				"BOT_BRAIN_LLM_MODEL":          "gpt-4o-mini",
				"BOT_BRAIN_LLM_API_KEY":        "sk-secret",
				"BOT_BRAIN_LLM_ALLOWED_MODELS": "gpt-4o-mini, gpt-4o",
				"BOT_BRAIN_LLM_TIMEOUT":        "1s",
			},
			check: func(t *testing.T, c config.Config) {
				if len(c.LLM.AllowedModels) != 2 {
					t.Errorf("allowed models = %v", c.LLM.AllowedModels)
				}
				if c.Redacted().LLM.APIKey == "sk-secret" {
					t.Error("Redacted() leaked the API key")
				}
			},
		},
		{
			name: "anthropic-compatible gateway",
			env: map[string]string{
				"BOT_BRAIN_LLM_ENABLED":  "true",
				"BOT_BRAIN_LLM_BASE_URL": "https://gateway.internal/anthropic/v1",
				"BOT_BRAIN_LLM_MODEL":    "claude-sonnet",
				"BOT_BRAIN_LLM_PROVIDER": "anthropic",
				"BOT_BRAIN_LLM_TIMEOUT":  "1s",
			},
			check: func(t *testing.T, c config.Config) {
				if c.LLM.Provider != llm.ProviderAnthropic {
					t.Errorf("provider = %q", c.LLM.Provider)
				}
			},
		},
		{
			name: "a model timeout that eats the whole budget is a startup failure",
			env: map[string]string{
				"BOT_BRAIN_LLM_ENABLED":      "true",
				"BOT_BRAIN_LLM_BASE_URL":     "http://vllm:8000/v1",
				"BOT_BRAIN_LLM_MODEL":        "m",
				"BOT_BRAIN_LLM_TIMEOUT":      "5s",
				"BOT_BRAIN_DEFAULT_DEADLINE": "2s",
			},
			wantErr: "must be shorter than",
		},
		{
			name:    "empty listen address",
			env:     map[string]string{"BOT_BRAIN_LISTEN": " "},
			wantErr: "",
			check: func(t *testing.T, c config.Config) {
				// Loopback, not ":8085". The default must not put an
				// unauthenticated planning endpoint on every interface; a
				// container overrides BOT_BRAIN_LISTEN to ":8085" on purpose.
				if c.ListenAddr != "127.0.0.1:8085" {
					t.Errorf("blank listen fell back to %q, want the loopback default", c.ListenAddr)
				}
			},
		},
		{
			name:    "non-positive batch cap",
			env:     map[string]string{"BOT_BRAIN_MAX_BATCH": "0"},
			wantErr: "must be positive",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := config.Load(env(tc.env))
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want one containing %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tc.check != nil {
				tc.check(t, cfg)
			}
		})
	}
}

// A config dump must never be able to carry a credential into a log.
func TestRedactedIsSafeToLog(t *testing.T) {
	cfg, err := config.Load(env(map[string]string{
		"BOT_BRAIN_LLM_ENABLED":  "true",
		"BOT_BRAIN_LLM_BASE_URL": "https://api.openai.com/v1",
		"BOT_BRAIN_LLM_MODEL":    "gpt-4o-mini",
		"BOT_BRAIN_LLM_API_KEY":  "sk-do-not-log-me",
		"BOT_BRAIN_LLM_TIMEOUT":  "500ms",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(dump(cfg.Redacted()), "sk-do-not-log-me") {
		t.Fatal("the redacted config still contains the API key")
	}
}

func dump(c config.Config) string {
	return strings.Join([]string{c.ListenAddr, c.LLM.BaseURL, c.LLM.Model, c.LLM.APIKey}, " ")
}

// A value that is SET but unparseable must fail startup, not fall back.
//
// The old behaviour is the reason this test exists: BOT_BRAIN_MAX_BATCH=lots
// started a healthy service on 2048 and logged nothing, so the operator saw a
// green service ignoring the value they had just configured.
func TestUnparseableValuesFailStartup(t *testing.T) {
	cases := []struct {
		key, value string
	}{
		{"BOT_BRAIN_MAX_BATCH", "lots"},
		{"BOT_BRAIN_WORKERS", "many"},
		{"BOT_BRAIN_MAX_BODY_BYTES", "16MB"}, // a plausible typo: not an integer
		{"BOT_BRAIN_INTENT_TTL", "half a minute"},
		{"BOT_BRAIN_LLM_ENABLED", "yes please"},
		{"BOT_BRAIN_RULE_REST_BELOW_HP_PCT", "forty"},
	}
	for _, tc := range cases {
		t.Run(tc.key, func(t *testing.T) {
			_, err := config.Load(func(k string) string {
				if k == tc.key {
					return tc.value
				}
				return ""
			})
			if err == nil {
				t.Fatalf("%s=%q was accepted; an unreadable value must not be silently replaced by the default", tc.key, tc.value)
			}
			// The message has to name the key AND the value, or an operator with
			// the same variable set in three places cannot tell which one to fix.
			if !strings.Contains(err.Error(), tc.key) {
				t.Errorf("error does not name the variable: %v", err)
			}
			if !strings.Contains(err.Error(), tc.value) {
				t.Errorf("error does not quote the offending value: %v", err)
			}
		})
	}
}

// Every bad variable is reported at once. Fixing a compose file one restart per
// typo is a bad way to spend an afternoon.
func TestAllBadValuesReportedTogether(t *testing.T) {
	env := map[string]string{
		"BOT_BRAIN_MAX_BATCH": "lots",
		"BOT_BRAIN_WORKERS":   "many",
	}
	_, err := config.Load(func(k string) string { return env[k] })
	if err == nil {
		t.Fatal("expected an error")
	}
	for k := range env {
		if !strings.Contains(err.Error(), k) {
			t.Errorf("%s missing from the combined error: %v", k, err)
		}
	}
}

// Unset is still the documented way to say "I do not care".
func TestUnsetValuesUseDefaults(t *testing.T) {
	c, err := config.Load(func(string) string { return "" })
	if err != nil {
		t.Fatalf("an entirely empty environment must produce a working service: %v", err)
	}
	if c.MaxBatch != contract.DefaultMaxBatch {
		t.Errorf("MaxBatch = %d, want %d", c.MaxBatch, contract.DefaultMaxBatch)
	}
	if c.MaxBodyBytes != contract.DefaultMaxBodyBytes {
		t.Errorf("MaxBodyBytes = %d, want %d", c.MaxBodyBytes, contract.DefaultMaxBodyBytes)
	}
}

// A value that parses but is nonsense is still rejected, by validate rather
// than by the parser. Zero parses fine; it also means "read no bytes".
func TestZeroMaxBodyBytesRejected(t *testing.T) {
	_, err := config.Load(func(k string) string {
		if k == "BOT_BRAIN_MAX_BODY_BYTES" {
			return "0"
		}
		return ""
	})
	if err == nil {
		t.Fatal("BOT_BRAIN_MAX_BODY_BYTES=0 was accepted; it would reject every request")
	}
}
