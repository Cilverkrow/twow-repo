// Package config loads the service configuration from the environment.
//
// Environment only, no config file: the service runs in a container, the
// deployment already renders environment, and a second configuration mechanism
// is a second place for a secret to leak into Git (ADR-0024 invariant 5).
//
// Every value has a default that produces a working service, and the default
// has inference OFF. A bot brain that plans with rules is useful; a bot brain
// that will not start because no model is configured is not.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/llm"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// Config is the whole service configuration.
type Config struct {
	// ListenAddr is the HTTP bind address. Defaults to LOOPBACK, not to every
	// interface.
	//
	// ":8085" in Go means 0.0.0.0:8085, so the previous default put an
	// unauthenticated planning endpoint -- one that also holds an LLM API key in
	// its config -- on whatever network the machine happens to be attached to.
	// The symptom is mild and the cause is not: running the binary on Windows
	// raises a firewall prompt, which is the operating system correctly asking
	// why a game AI service wants to accept connections from the LAN.
	//
	// Containers override this to ":8085" deliberately: there the network
	// namespace is the isolation boundary, the process must accept from sibling
	// containers, and deploy/compose/bot-brain.yml publishes it to the host as
	// 127.0.0.1:8085 anyway. See BOT_BRAIN_LISTEN in that file.
	ListenAddr string
	// MaxBatch caps snapshots per request.
	MaxBatch int
	// DefaultDeadline applies when the server sends no deadline_ms.
	DefaultDeadline time.Duration
	// IntentTTL is how long an intent stays valid, expressed in the server's
	// clock. It must be short: a plan computed from a snapshot the worldserver
	// took seconds ago should stop being applied rather than be applied late.
	IntentTTL time.Duration
	// Workers bounds concurrent planning goroutines. Zero means unbounded
	// within a batch, which is fine for the rule planner and not for the LLM.
	Workers int
	// ShutdownGrace bounds graceful shutdown (ADR-0006).
	ShutdownGrace time.Duration
	// Rule thresholds.
	Rule rule.Thresholds
	// LLM backend configuration.
	LLM llm.Config
	// LogLevel is "debug", "info" or "warn".
	LogLevel string
}

// Load reads configuration from the environment.
func Load(getenv func(string) string) (Config, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	c := Config{
		ListenAddr:      str(getenv, "BOT_BRAIN_LISTEN", "127.0.0.1:8085"),
		MaxBatch:        num(getenv, "BOT_BRAIN_MAX_BATCH", contract.DefaultMaxBatch),
		DefaultDeadline: dur(getenv, "BOT_BRAIN_DEFAULT_DEADLINE", 2*time.Second),
		IntentTTL:       dur(getenv, "BOT_BRAIN_INTENT_TTL", 30*time.Second),
		Workers:         num(getenv, "BOT_BRAIN_WORKERS", 32),
		ShutdownGrace:   dur(getenv, "BOT_BRAIN_SHUTDOWN_GRACE", 10*time.Second),
		LogLevel:        str(getenv, "BOT_BRAIN_LOG_LEVEL", "info"),
		Rule: rule.Thresholds{
			RestBelowHealthPct:           flt(getenv, "BOT_BRAIN_RULE_REST_BELOW_HP_PCT", 45),
			RepairBelowDurabilityPct:     flt(getenv, "BOT_BRAIN_RULE_REPAIR_BELOW_DUR_PCT", 25),
			VendorWhenFreeBagSlotsAtMost: uint32(num(getenv, "BOT_BRAIN_RULE_VENDOR_FREE_SLOTS", 1)),
			MaxTravelYards:               flt(getenv, "BOT_BRAIN_RULE_MAX_TRAVEL_YARDS", 1500),
		},
		LLM: llm.Config{
			Enabled:  boolean(getenv, "BOT_BRAIN_LLM_ENABLED", false),
			BaseURL:  str(getenv, "BOT_BRAIN_LLM_BASE_URL", ""),
			Model:    str(getenv, "BOT_BRAIN_LLM_MODEL", ""),
			APIKey:   getenv("BOT_BRAIN_LLM_API_KEY"),
			Provider: llm.Provider(str(getenv, "BOT_BRAIN_LLM_PROVIDER", string(llm.ProviderOpenAI))),
			// The default timeout is deliberately far below any plausible
			// worldserver planning cadence. A local 7B on CPU takes ~8 s
			// (LLM-011); with this default such a backend never answers and
			// every batch falls back to rules, which is the correct visible
			// outcome rather than a hidden stall.
			Timeout:        dur(getenv, "BOT_BRAIN_LLM_TIMEOUT", 1500*time.Millisecond),
			MaxTokens:      num(getenv, "BOT_BRAIN_LLM_MAX_TOKENS", 1024),
			Temperature:    flt(getenv, "BOT_BRAIN_LLM_TEMPERATURE", 0),
			MaxBotsPerCall: num(getenv, "BOT_BRAIN_LLM_MAX_BOTS_PER_CALL", 16),
			AllowedModels:  list(getenv, "BOT_BRAIN_LLM_ALLOWED_MODELS"),
		},
	}
	return c, c.validate()
}

func (c Config) validate() error {
	if c.ListenAddr == "" {
		return fmt.Errorf("BOT_BRAIN_LISTEN must not be empty")
	}
	if c.MaxBatch <= 0 {
		return fmt.Errorf("BOT_BRAIN_MAX_BATCH must be positive, got %d", c.MaxBatch)
	}
	if c.IntentTTL <= 0 {
		return fmt.Errorf("BOT_BRAIN_INTENT_TTL must be positive, got %s", c.IntentTTL)
	}
	if c.LLM.Enabled && c.LLM.Timeout >= c.DefaultDeadline {
		// If the model may take as long as the whole batch budget, the fallback
		// has no time left to run and bots get nothing. This is the one
		// misconfiguration that quietly defeats the entire design, so it is a
		// startup failure rather than a warning.
		return fmt.Errorf("BOT_BRAIN_LLM_TIMEOUT (%s) must be shorter than BOT_BRAIN_DEFAULT_DEADLINE (%s), "+
			"or the deterministic fallback has no budget to answer in", c.LLM.Timeout, c.DefaultDeadline)
	}
	return nil
}

// Redacted returns a copy safe to log at startup.
func (c Config) Redacted() Config {
	c.LLM = c.LLM.Redacted()
	return c
}

func str(getenv func(string) string, key, def string) string {
	if v := strings.TrimSpace(getenv(key)); v != "" {
		return v
	}
	return def
}

func num(getenv func(string) string, key string, def int) int {
	if v := strings.TrimSpace(getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func flt(getenv func(string) string, key string, def float64) float64 {
	if v := strings.TrimSpace(getenv(key)); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func boolean(getenv func(string) string, key string, def bool) bool {
	if v := strings.TrimSpace(getenv(key)); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return def
}

func dur(getenv func(string) string, key string, def time.Duration) time.Duration {
	v := strings.TrimSpace(getenv(key))
	if v == "" {
		return def
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	// Bare integers are milliseconds, because that is the unit the rest of the
	// contract uses and mixing "1500" and "1500ms" in a compose file is a
	// footgun worth closing.
	if n, err := strconv.Atoi(v); err == nil {
		return time.Duration(n) * time.Millisecond
	}
	return def
}

func list(getenv func(string) string, key string) []string {
	v := strings.TrimSpace(getenv(key))
	if v == "" {
		return nil
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
