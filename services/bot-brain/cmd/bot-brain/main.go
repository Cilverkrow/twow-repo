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
	// Nil unless a store is configured; httpapi treats that as "do not keep
	// observations", which is the mode the service runs in without a database.
	var memoryRecorder memory.Recorder
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
		// onError is passed in rather than assigned afterwards: the workers that
		// read it start inside the constructor, so a later assignment would race
		// every one of them.
		recorder := memory.NewAsyncRecorder(traitStore, 4096, 2, func(err error, dropped uint64) {
			if err != nil {
				log.Warn("could not record what happened to a bot", "err", err)
				return
			}
			// A drop is not an error: the queue is bounded on purpose so a slow
			// database costs history rather than a late tick. Warned anyway,
			// because losing history silently is how you end up trusting a
			// record that has holes in it.
			log.Warn("observation dropped; memory has a hole in it", "dropped_total", dropped)
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
		fb = &planner.Fallback{
			Primary:   llmP,
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
			"api_key_set", cfg.LLM.APIKey != "")
	}

	srv := httpapi.New(httpapi.Options{
		Planner:         active,
		MaxBatch:        cfg.MaxBatch,
		MaxBodyBytes:    cfg.MaxBodyBytes,
		DefaultDeadline: cfg.DefaultDeadline,
		IntentTTL:       cfg.IntentTTL,
		Memory:          memoryRecorder,
		Metrics:         reg,
		Logger:          log,
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
