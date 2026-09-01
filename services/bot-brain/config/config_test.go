package config_test

import (
	"strings"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/config"
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
			name: "garbage falls back to the default rather than failing to start",
			env:  map[string]string{"BOT_BRAIN_INTENT_TTL": "soon"},
			check: func(t *testing.T, c config.Config) {
				if c.IntentTTL != 30*time.Second {
					t.Errorf("ttl = %s, want the 30s default", c.IntentTTL)
				}
			},
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
