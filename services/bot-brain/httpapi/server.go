// Package httpapi is the transport.
//
// HTTP/JSON, not gRPC, deliberately and for now. ARCH-001 names protobuf over
// gRPC as the eventual transport and that is still right, but the first
// deliverable has to be readable and pokeable with curl by whoever is writing
// the C++ side. The contract package is transport-agnostic: moving to gRPC is
// generating a .proto from those structs and adding a second handler, not a
// redesign.
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/metrics"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
)

// Options configure a [Server].
type Options struct {
	// Planner is what actually plans. In production this is a
	// [planner.Fallback] wrapping the LLM planner over the rule planner.
	Planner planner.Planner
	// MaxBatch caps snapshots per request.
	MaxBatch int
	// DefaultDeadline applies when the request carries no deadline_ms.
	DefaultDeadline time.Duration
	// IntentTTL is passed to planners so they can stamp expiry in the server's
	// clock.
	IntentTTL time.Duration
	// Metrics registry. Required.
	Metrics *metrics.Registry
	// Logger. Nil means slog.Default.
	Logger *slog.Logger
	// Now is injectable for tests. Nil means time.Now. It is used only for
	// measuring the service's own latency, never for stamping intent expiry --
	// that always comes from the server's clock in the request.
	Now func() time.Time
}

// Server serves the brain API.
type Server struct {
	opts  Options
	mux   *http.ServeMux
	log   *slog.Logger
	now   func() time.Time
	ready struct {
		mu    sync.RWMutex
		value bool
	}
}

// Metric names. Exported as constants so dashboards and alerts can be written
// against something that a rename would break at compile time.
const (
	MetricPlanRequests    = "botbrain_plan_requests_total"
	MetricPlanSnapshots   = "botbrain_plan_snapshots_total"
	MetricPlanIntents     = "botbrain_plan_intents_total"
	MetricPlanErrors      = "botbrain_plan_errors_total"
	MetricFallbackIntents = "botbrain_fallback_intents_total"
	MetricVersionSkew     = "botbrain_version_skew_total"
	MetricUnknownFields   = "botbrain_unknown_fields_total"
	MetricPlanSeconds     = "botbrain_plan_duration_seconds"
	MetricReady           = "botbrain_ready"
	MetricDroppedIntents  = "botbrain_dropped_intents_total"
)

// New builds a server and registers routes.
func New(opts Options) *Server {
	if opts.MaxBatch <= 0 {
		opts.MaxBatch = contract.DefaultMaxBatch
	}
	if opts.DefaultDeadline <= 0 {
		opts.DefaultDeadline = 2 * time.Second
	}
	if opts.IntentTTL <= 0 {
		opts.IntentTTL = 30 * time.Second
	}
	if opts.Metrics == nil {
		opts.Metrics = metrics.New()
	}
	s := &Server{
		opts: opts,
		mux:  http.NewServeMux(),
		log:  opts.Logger,
		now:  opts.Now,
	}
	if s.log == nil {
		s.log = slog.Default()
	}
	if s.now == nil {
		s.now = time.Now
	}
	s.describeMetrics()
	s.ready.value = true

	s.mux.HandleFunc("GET /healthz", s.handleHealth)
	s.mux.HandleFunc("GET /readyz", s.handleReady)
	s.mux.HandleFunc("GET /metrics", s.handleMetrics)
	s.mux.HandleFunc("GET /v1/contract", s.handleContract)
	s.mux.HandleFunc("POST /v1/plan", s.handlePlan)
	return s
}

func (s *Server) describeMetrics() {
	m := s.opts.Metrics
	m.Describe(MetricPlanRequests, "Plan requests received, by outcome.")
	m.Describe(MetricPlanSnapshots, "Snapshots decoded across all plan requests.")
	m.Describe(MetricPlanIntents, "Intents returned, by source planner.")
	m.Describe(MetricPlanErrors, "Per-bot planning errors, by code.")
	m.Describe(MetricFallbackIntents, "Intents produced by the fallback planner, by reason. Persistently high means the primary planner is not working.")
	m.Describe(MetricVersionSkew, "Requests refused because the peer speaks an unsupported contract major.")
	m.Describe(MetricUnknownFields, "Fields sent by the peer that this build ignores. Non-zero is the normal signature of a newer worldserver during a rolling deploy.")
	m.Describe(MetricPlanSeconds, "Wall time spent planning one batch, in seconds.")
	m.Describe(MetricReady, "1 when the service is ready to serve plan requests.")
	m.Describe(MetricDroppedIntents, "Intents discarded before being returned, by reason.")
}

// Handler exposes the mux.
func (s *Server) Handler() http.Handler { return s.mux }

// SetReady flips readiness. Shutdown calls SetReady(false) before draining so
// a load balancer stops sending batches while in-flight ones finish.
func (s *Server) SetReady(v bool) {
	s.ready.mu.Lock()
	s.ready.value = v
	s.ready.mu.Unlock()
}

func (s *Server) isReady() bool {
	s.ready.mu.RLock()
	defer s.ready.mu.RUnlock()
	return s.ready.value
}

// handleHealth is liveness: the process is up. It never consults the planner,
// because a liveness probe that fails when a dependency is down gets the
// container killed for a condition a restart cannot fix.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":           "ok",
		"contract_version": contract.Version,
	})
}

// handleReady is readiness: this instance can serve plan requests.
//
// Note what it does NOT depend on: the LLM backend. A brain with a dead model
// still plans, so reporting unready would remove a working instance from
// rotation. Readiness tracks the planner that is supposed to always work.
func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	ready := s.isReady() && s.opts.Planner != nil && s.opts.Planner.Ready()
	code := http.StatusOK
	if !ready {
		code = http.StatusServiceUnavailable
	}
	s.opts.Metrics.SetGauge(MetricReady, boolToFloat(ready))
	writeJSON(w, code, map[string]any{
		"ready":   ready,
		"planner": plannerName(s.opts.Planner),
	})
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	s.opts.Metrics.SetGauge(MetricReady, boolToFloat(s.isReady()))
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(s.opts.Metrics.String()))
}

// handleContract lets the C++ side discover the contract at startup and refuse
// to enable the brain path on a major mismatch, instead of finding out one
// dropped intent at a time in production.
func (s *Server) handleContract(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, contract.Info(s.opts.MaxBatch))
}

// handlePlan is the batch endpoint.
func (s *Server) handlePlan(w http.ResponseWriter, r *http.Request) {
	start := s.now()
	req, decoded, err := contract.DecodePlanRequest(r.Body, s.opts.MaxBatch)
	if err != nil {
		s.writeDecodeError(w, err)
		return
	}
	if decoded.UnknownFields > 0 {
		s.opts.Metrics.Inc(MetricUnknownFields, float64(decoded.UnknownFields))
		s.log.Warn("peer sent fields this build ignores",
			"count", decoded.UnknownFields,
			"sample", decoded.UnknownFieldNames,
			"peer_version", req.ContractVersion,
			"our_version", contract.Version)
	}

	requestID := req.RequestID
	if requestID == "" {
		requestID = planner.NewIntentID()
	}

	// Split snapshots into plannable and rejected. A bad snapshot costs its own
	// bot an intent and nothing more: at 1000 bots per batch, failing the whole
	// call over one malformed entry would be a self-inflicted outage.
	plannable := make([]contract.Snapshot, 0, len(req.Snapshots))
	var planErrors []contract.PlanError
	for i := range req.Snapshots {
		if err := req.Snapshots[i].Validate(); err != nil {
			s.opts.Metrics.Inc(MetricPlanErrors, 1, "code", contract.CodeMalformed)
			planErrors = append(planErrors, contract.PlanError{
				Bot:     req.Snapshots[i].Bot,
				Code:    contract.CodeMalformed,
				Message: err.Error(),
			})
			continue
		}
		plannable = append(plannable, req.Snapshots[i])
	}

	deadline := s.opts.DefaultDeadline
	if req.DeadlineMS > 0 {
		deadline = time.Duration(req.DeadlineMS) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(r.Context(), deadline)
	defer cancel()

	intents, planErr := s.opts.Planner.Plan(ctx, planner.Request{
		Snapshots:   plannable,
		ServerNowMS: req.SentAtMS,
		IntentTTLMS: s.opts.IntentTTL.Milliseconds(),
		RequestID:   requestID,
	})

	degraded := ""
	if planErr != nil {
		// Even a failing planner returns a partial answer. Report the failure
		// in stats and ship what there is: the worldserver runs tier-0 AI for
		// the bots it got nothing for, which is exactly the designed
		// degradation (ADR-0024 invariant 6).
		degraded = "planner_error"
		if errors.Is(planErr, context.DeadlineExceeded) {
			degraded = "deadline_exceeded"
		}
		s.log.Warn("planner returned an error; serving partial results",
			"request_id", requestID, "err", planErr, "intents", len(intents), "snapshots", len(plannable))
	}

	// Drop anything addressed to a bot that was not in this batch. This is the
	// last line of defence for ADR-0024 invariant 1: a planner bug must never
	// be able to deliver an intent to a bot the server did not ask about.
	asked := make(map[contract.BotID]bool, len(plannable))
	for i := range plannable {
		asked[plannable[i].Bot] = true
	}
	kept := intents[:0]
	fallbackCount := 0
	for _, in := range intents {
		if !asked[in.Bot] {
			s.opts.Metrics.Inc(MetricDroppedIntents, 1, "reason", "unasked_bot")
			s.log.Error("planner returned an intent for a bot that was not in the batch; dropped",
				"request_id", requestID, "bot", in.Bot.String(), "planner", plannerName(s.opts.Planner))
			continue
		}
		if err := in.Validate(); err != nil {
			s.opts.Metrics.Inc(MetricDroppedIntents, 1, "reason", "invalid")
			continue
		}
		if in.Source == "fallback" {
			fallbackCount++
		}
		s.opts.Metrics.Inc(MetricPlanIntents, 1, "source", nonEmpty(in.Source, "unknown"))
		kept = append(kept, in)
	}
	intents = kept

	// Bots that were plannable but got no intent are reported so the caller can
	// see the gap rather than infer it.
	answered := make(map[contract.BotID]bool, len(intents))
	for _, in := range intents {
		answered[in.Bot] = true
	}
	for i := range plannable {
		if !answered[plannable[i].Bot] {
			s.opts.Metrics.Inc(MetricPlanErrors, 1, "code", contract.CodeBotUnplannable)
			planErrors = append(planErrors, contract.PlanError{
				Bot:     plannable[i].Bot,
				Code:    contract.CodeBotUnplannable,
				Message: "no planner produced an intent for this bot",
			})
		}
	}

	elapsed := s.now().Sub(start)
	s.opts.Metrics.Inc(MetricPlanRequests, 1, "outcome", nonEmpty(degraded, "ok"))
	s.opts.Metrics.Inc(MetricPlanSnapshots, float64(len(req.Snapshots)))
	s.opts.Metrics.Observe(MetricPlanSeconds, elapsed.Seconds())
	if fallbackCount > 0 {
		s.opts.Metrics.Inc(MetricFallbackIntents, float64(fallbackCount))
	}

	writeJSON(w, http.StatusOK, contract.PlanResponse{
		ContractVersion: decoded.Effective.String(),
		RequestID:       requestID,
		Intents:         intents,
		Errors:          planErrors,
		Stats: contract.PlanStats{
			SnapshotsIn:    len(req.Snapshots),
			IntentsOut:     len(intents),
			FallbackUsed:   fallbackCount,
			PlanMS:         elapsed.Milliseconds(),
			UnknownFields:  decoded.UnknownFields,
			DegradedReason: degraded,
		},
	})
}

// writeDecodeError maps contract errors onto status codes the C++ side can act
// on without parsing prose.
func (s *Server) writeDecodeError(w http.ResponseWriter, err error) {
	code := contract.CodeMalformed
	status := http.StatusBadRequest
	switch {
	case errors.Is(err, contract.ErrVersionSkew):
		code = contract.CodeVersionSkew
		// 409 rather than 400: the request is well-formed, the two sides simply
		// cannot agree. The worldserver's correct reaction is to disable the
		// brain path and keep running in-core AI, not to retry.
		status = http.StatusConflict
		s.opts.Metrics.Inc(MetricVersionSkew, 1)
	case errors.Is(err, contract.ErrBatchTooLarge):
		code = contract.CodeBatchTooLarge
		status = http.StatusRequestEntityTooLarge
	}
	s.opts.Metrics.Inc(MetricPlanRequests, 1, "outcome", code)
	writeJSON(w, status, map[string]any{
		"code":             code,
		"message":          err.Error(),
		"contract_version": contract.Version,
		"supported_majors": contract.SupportedMajors,
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func plannerName(p planner.Planner) string {
	if p == nil {
		return "none"
	}
	return p.Name()
}

func nonEmpty(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func boolToFloat(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
