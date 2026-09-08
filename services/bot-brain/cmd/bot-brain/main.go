// Command bot-brain is the out-of-process bot planning service (ARCH-001).
//
// It listens for batches of bot snapshots and answers with intents. It holds no
// per-bot state between requests: durable bot state belongs to the worldserver
// and its schema, and this process may be killed, scaled or replaced at any
// moment without a bot noticing.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/config"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/httpapi"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/metrics"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/async"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/identity"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/identity/mysqlstore"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/llm"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/memory"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

// Build metadata, set with -ldflags -X at image build time. They are logged at
// startup so a running container can be tied back to a commit without exec'ing
// into it -- which the scratch runtime image cannot do anyway.
var (
	version = "dev"
	commit  = "unknown"
)

func main() {
	// `bot-brain healthcheck` probes the local /healthz and exits 0 or 1. It
	// exists because the runtime image is scratch: there is no curl or wget for
	// a Docker HEALTHCHECK to call, so the binary is its own probe.
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		slog.Error("bot-brain exited", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level(cfg.LogLevel)}))
	slog.SetDefault(log)

	reg := metrics.New()
	// Two gauges, deliberately separate, because they have OPPOSITE recovery
	// semantics and a dashboard that merges them reproduces the mistake this
	// repository has already made once in writing.
	reg.Describe("botbrain_llm_breaker_open",
		"1 while the LLM circuit breaker is open. Reopens by itself on a timer; a spike here is a bad minute at the endpoint.")
	reg.Describe("botbrain_llm_token_budget_stopped",
		"1 once the token budget has latched shut. NEVER reopens: this process will not call the model again until it is restarted. Alert on this.")
	// Nil unless a store is configured; httpapi treats that as "do not keep
	// observations", which is the mode the service runs in without a database.
	var memoryRecorder memory.Recorder
	// Non-nil only when inference runs off the tick; stopped on shutdown so a
	// round in flight is not abandoned mid-call.
	var asyncP *async.Planner
	ruleP := rule.New(cfg.Rule)

	// Per-bot identity. Without a DSN the resolver is nil, traits come from the
	// UUID alone, and bots differ from each other without changing over time --
	// a supported mode, not a degraded one, and the one the service ran in
	// before cv_brain was reachable from here.
	if cfg.TraitDSN != "" {
		traitStore, err := mysqlstore.Open(cfg.TraitDSN)
		if err != nil {
			// A malformed DSN is an operator typo, and starting anyway would
			// mean traits silently never load. That is the same reasoning as
			// the rest of Load(): a value someone actually typed is held to
			// being meaningful.
			return fmt.Errorf("trait store: %w", err)
		}
		defer traitStore.Close()

		// Reachability is checked but NOT required. A brain that refuses to
		// start because the trait store is down is a brain that cannot plan for
		// want of a value it has a safe default for.
		pingCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err = traitStore.Ping(pingCtx)
		cancel()
		if err != nil {
			log.Warn("trait store unreachable; bots keep the traits they were born with",
				"err", err)
		} else {
			log.Info("trait store connected", "traits", "cv_brain.bot_trait")
		}

		// The same store serves memory. One connection pool, because the two
		// tables live in the same schema and a second pool would double the
		// connection count against a database that is also carrying the
		// worldserver's traffic.
		// What a bot becomes, from what happened to it. Runs on the recorder's
		// worker, never on the planning path: it reads history and writes a trait,
		// which is more database work than a plan can afford to wait for.
		learner := &memory.Learner{
			Reader:  traitStore,
			Traits:  traitStore,
			Values:  traitStore,
			Derived: func(uuid string) float64 { return identity.Derive(uuid).Boldness },
			OnChange: func(uuid, trait string, from, to float64, reason string) {
				// Logged at info, not debug. A bot's personality changing is a
				// rare and consequential event, and the reason is in words so the
				// question "why is this bot timid" has an answer.
				log.Info("a bot changed", "bot", uuid, "trait", trait,
					"from", from, "to", to, "because", reason)
			},
		}

		// Callbacks are passed in rather than assigned afterwards: the workers
		// that read them start inside the constructor, so a later assignment
		// would race every one of them.
		recorder := memory.NewAsyncRecorder(traitStore, memory.AsyncOptions{
			QueueSize: 4096,
			Workers:   2,
			OnError: func(err error, dropped uint64) {
				if err != nil {
					log.Warn("could not record what happened to a bot", "err", err)
					return
				}
				// A drop is not an error: the queue is bounded on purpose so a
				// slow database costs history rather than a late tick. Warned
				// anyway, because losing history silently is how you end up
				// trusting a record that has holes in it.
				log.Warn("observation dropped; memory has a hole in it", "dropped_total", dropped)
			},
			AfterRecord: func(ctx context.Context, uuid string) {
				if err := learner.Observe(ctx, uuid); err != nil {
					log.Warn("could not update what a bot has become", "bot", uuid, "err", err)
				}
			},
		})
		defer recorder.Stop()
		memoryRecorder = recorder
		ruleP.Memory = traitStore
		ruleP.OnMemoryError = func(err error) {
			log.Warn("memory lookup failed; planning without history", "err", err)
		}

		ruleP.Traits = &identity.Resolver{
			Store: traitStore,
			// Logged here rather than inside the resolver: the planner is a
			// pure decision path, and handing it a logger is how a function
			// that can be tested without a world stops being one.
			OnStoreError: func(err error) {
				log.Warn("trait lookup failed; falling back to derived traits", "err", err)
			},
		}
	}

	// The planner chain. The rule planner is always the last word: whatever sits
	// in front of it may be slow, wrong or absent, and bots still get planned.
	var active planner.Planner = ruleP
	var fb *planner.Fallback

	llmP, llmErr := llm.New(cfg.LLM)
	switch {
	case errors.Is(llmErr, llm.ErrDisabled):
		log.Info("llm planner disabled; planning with rules only",
			"planner", ruleP.Name())
	case llmErr != nil:
		// A misconfigured model is not a reason to refuse to start. The service
		// is designed to work without inference, so it starts without it and
		// says so loudly.
		log.Error("llm planner misconfigured; planning with rules only", "err", llmErr)
	default:
		// The primary the fallback sees. With async on it is a lane that
		// serves what the model decided on earlier ticks and never blocks;
		// with it off the model races the tick, as before.
		var primary planner.Planner = llmP
		if cfg.LLMAsync {
			asyncP = async.New(llmP, async.Options{
				MaxBotsPerRound: cfg.LLM.MaxBotsPerCall,
				Timeout:         cfg.LLMAsyncTimeout,
				MaxAttempts:     cfg.LLMMaxAttempts,
				MinInterval:     cfg.LLMMinInterval,
				OnError: func(err error) {
					log.Warn("background inference round failed", "err", err)
				},
			})
			defer asyncP.Stop()
			primary = asyncP
		}
		fb = &planner.Fallback{
			Primary:   primary,
			Secondary: ruleP,
			Timeout:   cfg.LLM.Timeout,
			OnFallback: func(count int, reason string) {
				// Batch-level reason. Per-intent fallback counting lives in the
				// HTTP layer, which reads it off the intents themselves; counting
				// the same thing twice into one metric would double it.
				reg.Inc("botbrain_fallback_batches_total", 1, "reason", reason)
				_ = count
			},
		}
		active = fb
		log.Info("llm planner enabled",
			"base_url", cfg.LLM.BaseURL,
			"model", cfg.LLM.Model,
			"provider", cfg.LLM.Provider,
			"timeout", cfg.LLM.Timeout,
			"api_key_set", cfg.LLM.APIKey != "",
			// Named so the log answers "why is the model never used" and "why
			// did that intent arrive three ticks late" without a reader having
			// to know this flag exists.
			"async", cfg.LLMAsync)
	}

	// Dialogue, if it is on. It is built from llmP rather than from a config,
	// which is what makes the endpoint, the credential, the circuit breaker and
	// the token budget genuinely shared rather than merely configured the same:
	// there is one *llm.Planner in this process and both callers go through it.
	//
	// Nil is a supported state and reaches httpapi as one: the route still
	// exists, and every bot answers with reason "dialogue_disabled". The C++
	// side then has one shape to handle instead of a 404 as a third outcome.
	var speaker httpapi.Speaker
	if llmP != nil && llmErr == nil {
		dialogueP, dialogueErr := llm.NewDialogue(llmP, cfg.Dialogue)
		switch {
		case errors.Is(dialogueErr, llm.ErrDialogueDisabled):
			log.Info("bot dialogue disabled; bots will not talk")
		case dialogueErr != nil:
			// Same reasoning as the planner above: a misconfigured dialogue is
			// not a reason to refuse to start a service whose main job is
			// planning. It says so loudly and carries on.
			log.Error("bot dialogue misconfigured; bots will not talk", "err", dialogueErr)
		default:
			speaker = dialogueP
			log.Info("bot dialogue enabled",
				"model", cfg.LLM.Model,
				"max_tokens", cfg.Dialogue.MaxTokens,
				"timeout", cfg.Dialogue.Timeout,
				"max_in_flight", cfg.MaxDialogueInFlight,
				// Named because "why did planning stop using the model" and
				// "why are the bots quiet" have the same answer often enough
				// that the log should say the two share a budget.
				"token_budget", "shared with the planner")
		}
	} else if cfg.Dialogue.Enabled {
		log.Error("bot dialogue is enabled but there is no llm planner to borrow an endpoint from; bots will not talk")
	}

	srv := httpapi.New(httpapi.Options{
		Planner:              active,
		MaxBatch:             cfg.MaxBatch,
		MaxBodyBytes:         cfg.MaxBodyBytes,
		DefaultDeadline:      cfg.DefaultDeadline,
		IntentTTL:            cfg.IntentTTL,
		Memory:               memoryRecorder,
		Metrics:              reg,
		Logger:               log,
		Dialogue:             speaker,
		MaxDialogueBodyBytes: cfg.MaxDialogueBodyBytes,
		MaxDialogueInFlight:  cfg.MaxDialogueInFlight,
	})

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		// No WriteTimeout: a 2000-bot batch under a generous deadline is a
		// legitimately long response, and a fixed write timeout here would
		// truncate exactly the batches this service exists to serve.
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Read and written only by the ticker goroutine below.
	budgetLatchLogged := false

	// Periodically reopen the LLM circuit breaker so a recovered endpoint comes
	// back without a restart.
	if llmP != nil && llmErr == nil {
		go func() {
			t := time.NewTicker(30 * time.Second)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					// Published on the same timer that already exists rather
					// than on one of its own: these are slow-moving states, and
					// a second ticker to watch two booleans would be more
					// machinery than the thing it observes.
					reg.SetGauge("botbrain_llm_breaker_open", boolGauge(!llmP.Ready()))
					if budget := cfg.LLM.TokenBudget; budget != nil {
						stopped := budget.Stopped()
						reg.SetGauge("botbrain_llm_token_budget_stopped", boolGauge(stopped))
						if stopped && !budgetLatchLogged {
							// Once, not every tick. The state never changes back,
							// so repeating it would be a log line every 30
							// seconds for the life of the process.
							budgetLatchLogged = true
							log.Error("llm token budget has latched shut; this process will not call the model again",
								"remedy", "restart the service after deciding whether the provider's usage accounting is trustworthy")
						}
					}
					if !llmP.Ready() {
						log.Info("reopening llm circuit breaker for a trial batch")
						llmP.MarkHealthy()
					}
				}
			}
		}()
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("bot-brain listening",
			"addr", cfg.ListenAddr,
			"contract_version", contract.Version,
			"version", version,
			"commit", commit,
			"planner", active.Name(),
			"max_batch", cfg.MaxBatch,
			"intent_ttl", cfg.IntentTTL)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	// Graceful shutdown (ADR-0006): stop advertising readiness first so the
	// caller stops sending batches, then drain.
	log.Info("shutdown signal received; draining", "grace", cfg.ShutdownGrace)
	srv.SetReady(false)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	return httpServer.Shutdown(shutdownCtx)
}

// healthcheck performs a single GET against this container's own /healthz.
func healthcheck() int {
	addr := os.Getenv("BOT_BRAIN_LISTEN")
	if addr == "" {
		// Mirror config.Load's default. This probe runs inside the container,
		// where BOT_BRAIN_LISTEN is set explicitly, so this branch is for a bare
		// binary -- which now listens on loopback.
		addr = "127.0.0.1:8085"
	}
	if strings.HasPrefix(addr, ":") {
		addr = "127.0.0.1" + addr
	}
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://" + addr + "/healthz")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

// boolGauge renders a state as a gauge value. Prometheus has no boolean, and
// 0/1 is the convention every dashboard already expects.
func boolGauge(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

func level(s string) slog.Level {
	switch s {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
