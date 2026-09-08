package httpapi

// POST /v1/dialogue -- one bot, one line of chat, one reply or one silence.
//
// It sits next to /v1/plan and shares the decode-and-bound shape, but the two
// differ in three ways that are worth stating rather than discovering:
//
//   - The body cap is 16 KiB, not 16 MiB. A plan request is a batch; this is one
//     sentence. See contract.DefaultMaxDialogueBodyBytes.
//   - There is an in-flight limit, and /v1/plan has none. Planning is called by
//     one worldserver on a tick and is bounded by that; dialogue is called when a
//     player types, so the arrival rate is set by players.
//   - Every outcome that is not a malformed request is a 200. Silence is an
//     answer, not a failure -- see the note at the top of contract/dialogue.go.

import (
	"context"
	"errors"
	"net/http"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
)

// Speaker is what the dialogue endpoint needs from an inference backend.
//
// Declared here, on the consumer side, rather than in planner/llm, so that this
// package does not import the LLM planner in order to serve an endpoint that
// works without one. That is not a style preference: the whole service is built
// to run with inference off, and a transport that cannot compile without the
// model client would quietly make the model a build-time dependency of the
// transport.
//
// The implementation is *llm.Dialogue. Its Speak returns a response that is
// always safe to send plus an advisory error, and this handler relies on exactly
// that: it sends the response and logs the error.
type Speaker interface {
	// Speak answers one utterance. The returned response must always be
	// well-formed, including on every failure path.
	Speak(ctx context.Context, req *contract.DialogueRequest) (contract.DialogueResponse, error)
}

// Note what this interface does NOT have: a Ready. *llm.Dialogue has one and it
// is deliberately not required here, because there is nothing this handler would
// do with it. Speak already consults the breaker and the budget itself and
// answers with a reason rather than a call, so a readiness check here would be a
// second, racing copy of a decision that is already made correctly one layer
// down. /readyz does not consult it either, for the reason handleReady gives: a
// brain with a dead model still plans.

// Dialogue metric names.
const (
	MetricDialogueRequests = "botbrain_dialogue_requests_total"
	MetricDialogueSilence  = "botbrain_dialogue_silence_total"
	MetricDialogueSeconds  = "botbrain_dialogue_duration_seconds"
	MetricDialogueInFlight = "botbrain_dialogue_in_flight"
	MetricDialogueTraits   = "botbrain_dialogue_traits_applied_total"
)

// DefaultMaxDialogueInFlight bounds concurrent dialogue requests.
//
// Eight, and the number is chosen from what is behind it rather than from
// taste. Each in-flight request holds one model call, and a self-hosted 7B on
// CPU -- the deployment this repository actually measured, at about eight
// seconds a call (LLM-011) -- serves a handful of concurrent requests before
// each one gets slower rather than more of them getting served. Allowing more
// than the backend can absorb does not increase throughput; it converts a fast
// refusal into a slow one, and a slow refusal is the worse failure because the
// worldserver is holding a request open for it.
//
// Requests over the limit are shed immediately with SilenceBusy rather than
// queued. A queue here would be a place for load to accumulate during exactly
// the incident where accumulating load is fatal.
const DefaultMaxDialogueInFlight = 8

// handleDialogue answers one utterance.
func (s *Server) handleDialogue(w http.ResponseWriter, r *http.Request) {
	start := s.now()

	// Cap the body BEFORE decoding, for the reason spelled out on handlePlan:
	// the endpoint is unauthenticated by design and the decoder does not run
	// until the whole body is in memory.
	r.Body = http.MaxBytesReader(w, r.Body, s.opts.MaxDialogueBodyBytes)
	req, decoded, err := contract.DecodeDialogueRequest(r.Body)
	if err != nil {
		s.writeDialogueDecodeError(w, err)
		return
	}
	if decoded.UnknownFields > 0 {
		s.opts.Metrics.Inc(MetricUnknownFields, float64(decoded.UnknownFields))
		s.log.Warn("peer sent dialogue fields this build ignores",
			"count", decoded.UnknownFields,
			"sample", decoded.UnknownFieldNames,
			"peer_version", req.ContractVersion,
			"our_version", contract.Version)
	}

	requestID := req.RequestID
	if requestID == "" {
		requestID = planner.NewIntentID()
	}

	resp := contract.DialogueResponse{Bot: req.Bot}

	// Admission, in the order that costs least. Disabled is free, the in-flight
	// slot is a channel send, and only then is a model call attempted.
	switch {
	case s.opts.Dialogue == nil:
		// The steady state of a deployment with inference off, and the reason
		// this is a reason string rather than a 501: the worldserver's correct
		// behaviour is identical to "the bot had nothing to say", so making it
		// an error would give the C++ side an error path it must ignore.
		resp.Spoke, resp.Reason = false, contract.SilenceDisabled
	default:
		release, ok := s.acquireDialogueSlot()
		if !ok {
			// Counted once, at the bottom with every other silence, rather than
			// here as well.
			resp.Spoke, resp.Reason = false, contract.SilenceBusy
			break
		}
		out, speakErr := s.opts.Dialogue.Speak(r.Context(), req)
		release()
		if speakErr != nil {
			// Logged, never returned. Speak's contract is that the response is
			// safe to send on every path; the error is here so an operator can
			// tell a rate limit from a dead endpoint from a model writing
			// nonsense, all three of which look like a quiet bot from the game.
			s.log.Warn("dialogue produced no reply",
				"request_id", requestID, "bot", req.Bot.String(),
				"channel", req.Channel, "reason", out.Reason, "err", speakErr)
		}
		resp = out
		resp.Bot = req.Bot // never let a backend re-address a reply.
	}

	// Last gate. A response this side cannot vouch for becomes silence rather
	// than being posted to a game channel, and it is loud in the log because it
	// means two checks in this service disagree.
	if err := resp.Validate(); err != nil {
		s.log.Error("dialogue response failed its own validation; silencing",
			"request_id", requestID, "bot", req.Bot.String(), "err", err)
		resp = contract.DialogueResponse{Bot: req.Bot, Spoke: false, Reason: contract.SilenceFiltered}
	}

	elapsed := s.now().Sub(start)
	resp.ContractVersion = decoded.Effective.String()
	resp.RequestID = requestID
	resp.Stats.ReplyMS = elapsed.Milliseconds()
	resp.Stats.UnknownFields = decoded.UnknownFields

	outcome := "spoke"
	if !resp.Spoke {
		outcome = "silent"
		s.opts.Metrics.Inc(MetricDialogueSilence, 1, "reason", nonEmpty(resp.Reason, "unknown"))
	}
	s.opts.Metrics.Inc(MetricDialogueRequests, 1, "outcome", outcome)
	s.opts.Metrics.Inc(MetricDialogueTraits, float64(resp.Stats.TraitsApplied))
	s.opts.Metrics.Observe(MetricDialogueSeconds, elapsed.Seconds())

	writeJSON(w, http.StatusOK, resp)
}

// acquireDialogueSlot takes one of the in-flight slots, or reports that they are
// all taken. It never blocks: a caller that would have to wait is shed instead,
// so the worldserver gets its "no reply" immediately and is not left holding a
// connection open behind a queue.
func (s *Server) acquireDialogueSlot() (release func(), ok bool) {
	select {
	case s.dialogueSlots <- struct{}{}:
		s.opts.Metrics.SetGauge(MetricDialogueInFlight, float64(len(s.dialogueSlots)))
		return func() {
			<-s.dialogueSlots
			s.opts.Metrics.SetGauge(MetricDialogueInFlight, float64(len(s.dialogueSlots)))
		}, true
	default:
		return nil, false
	}
}

// writeDialogueDecodeError maps a decode failure onto a status code.
//
// Deliberately the same mapping as writeDecodeError, minus the batch case which
// cannot occur here, so that the C++ side has one rule for both endpoints. Note
// that this is the ONLY way a dialogue call produces a non-200: a request that
// decoded is always answered, however badly the model behaved afterwards.
func (s *Server) writeDialogueDecodeError(w http.ResponseWriter, err error) {
	code := contract.CodeMalformed
	status := http.StatusBadRequest
	switch {
	case errors.Is(err, contract.ErrVersionSkew):
		code = contract.CodeVersionSkew
		status = http.StatusConflict
		s.opts.Metrics.Inc(MetricVersionSkew, 1)
	case isBodyTooLarge(err):
		code = contract.CodeBatchTooLarge
		status = http.StatusRequestEntityTooLarge
	}
	s.opts.Metrics.Inc(MetricDialogueRequests, 1, "outcome", code)
	writeJSON(w, status, map[string]any{
		"code":             code,
		"message":          err.Error(),
		"contract_version": contract.Version,
		"supported_majors": contract.SupportedMajors,
	})
}
