package contract

import (
	"encoding/json"
	"fmt"
	"io"
	"strconv"
)

// DefaultMaxBatch is how many snapshots one call may carry. At ~1000 bots the
// worldserver is expected to send one or a few batches per planning tick rather
// than 1000 requests; this cap exists so a bug on the C++ side cannot turn into
// an unbounded allocation here.
const DefaultMaxBatch = 2048

// DefaultMaxBodyBytes bounds a plan request body at 16 MiB.
//
// It lives here beside DefaultMaxBatch because the two are the same limit
// expressed twice, and only this one actually binds: MaxBatch is enforced by
// the decoder, which does not run until the whole body is already in memory.
//
// Sized from the contract rather than picked. DefaultMaxBatch is 2048 snapshots
// and a fat one - 24 POIs, a full quest log - encodes to roughly 4 KiB, so a
// legitimate maximum batch is on the order of 8 MiB. Doubling that leaves room
// for a verbose encoder without leaving room for an attack.
const DefaultMaxBodyBytes = 16 << 20

// PlanRequest is one batch of snapshots.
//
// Batching is not an optimisation, it is the design. At 1000 bots and a
// planning cadence measured in seconds, per-bot round trips spend more time in
// HTTP than in planning.
type PlanRequest struct {
	// ContractVersion is "MAJOR.MINOR", the version the *sender* speaks.
	// Required. An absent version is refused rather than defaulted: see
	// [ParseVersion].
	ContractVersion string `json:"contract_version"`

	// RequestID correlates this batch across both processes' logs. The server
	// generates it; the brain echoes it. Absent is tolerated, and the brain
	// generates one so its own logs stay joinable.
	RequestID string `json:"request_id,omitempty"`

	// SentAtMS is the server's clock when it sent this batch, Unix ms. It is
	// the *only* time base shared between the two processes: the brain computes
	// [Intent.ExpiresAtMS] from it rather than from its own clock, because
	// container clocks skew and an intent's TTL must be meaningful to the side
	// that enforces it. Zero means the server did not stamp it, in which case
	// the brain cannot express expiry and emits intents with ExpiresAtMS zero.
	SentAtMS int64 `json:"sent_at_ms,omitempty"`

	// DeadlineMS is how long the server is willing to wait for this whole
	// batch, in milliseconds from when it sent it. The brain treats it as a
	// hard budget: when it runs out, every bot that has no answer yet gets the
	// deterministic fallback rather than nothing.
	//
	// Zero means the brain uses its own configured default. The server should
	// always set it, because the server is the side that knows how long it can
	// wait without missing a tick.
	DeadlineMS int64 `json:"deadline_ms,omitempty"`

	// Snapshots is the batch. Required and non-empty.
	Snapshots []Snapshot `json:"snapshots"`
}

// PlanResponse is the batch of intents.
//
// The response is *not* required to contain one intent per snapshot, and a bot
// with no intent is not an error: it means "nothing to suggest", and the
// worldserver keeps running tier-0 AI for it. Per-bot problems appear in
// [PlanResponse.Errors] and never fail the batch, because one malformed
// snapshot out of a thousand must not cost the other 999 their planning.
type PlanResponse struct {
	// ContractVersion is the version this response is stamped with, decided by
	// [Negotiate]. It may be a lower minor than this build's own, when the peer
	// is older.
	ContractVersion string `json:"contract_version"`
	// RequestID echoes [PlanRequest.RequestID], or is the one the brain
	// generated when the server sent none.
	RequestID string `json:"request_id"`
	// Intents, at most one per snapshot in this build.
	Intents []Intent `json:"intents"`
	// Errors are per-bot failures. See [PlanError].
	Errors []PlanError `json:"errors,omitempty"`
	// Stats is advisory telemetry for the caller's logs. Nothing in it is
	// contractual behaviour and a server may ignore it entirely.
	Stats PlanStats `json:"stats"`
}

// PlanError is a per-bot failure inside an otherwise successful batch.
type PlanError struct {
	// Bot is which bot failed. A zero BotID means the failure could not be
	// attributed, which itself is worth alerting on.
	Bot BotID `json:"bot"`
	// Code is one of the Code* constants. Stable; switch on this.
	Code string `json:"code"`
	// Message is human-readable and unstable. Never switch on this.
	Message string `json:"message"`
}

// PlanStats is advisory telemetry attached to each response.
type PlanStats struct {
	// SnapshotsIn is how many snapshots were decoded.
	SnapshotsIn int `json:"snapshots_in"`
	// IntentsOut is how many intents are in this response.
	IntentsOut int `json:"intents_out"`
	// FallbackUsed is how many intents came from a fallback planner because the
	// primary timed out or failed. A number that is persistently near
	// SnapshotsIn means the primary planner is not actually working, which is a
	// condition that would otherwise look like success.
	FallbackUsed int `json:"fallback_used"`
	// PlanMS is wall time spent planning inside the service.
	PlanMS int64 `json:"plan_ms"`
	// UnknownFields counts fields the sender included that this build does not
	// know. Non-zero is the normal signature of a newer worldserver talking to
	// an older brain; it is reported rather than rejected, and is the number to
	// watch during a rolling deployment.
	UnknownFields int `json:"unknown_fields"`
	// DegradedReason is non-empty when the response is worth less than it looks:
	// "deadline_exceeded", "planner_unavailable", "shedding". Advisory.
	DegradedReason string `json:"degraded_reason,omitempty"`
}

// ContractInfo is what GET /v1/contract returns. The C++ side fetches it at
// startup and logs a warning (or refuses to enable the brain path) when the
// majors do not overlap, so skew is discovered once at boot rather than
// silently, one dropped intent at a time, in production.
type ContractInfo struct {
	Version          string       `json:"version"`
	SupportedMajors  []int        `json:"supported_majors"`
	KnownIntentKinds []IntentKind `json:"known_intent_kinds"`
	MaxBatch         int          `json:"max_batch"`
}

// Info describes this build's contract.
func Info(maxBatch int) ContractInfo {
	return ContractInfo{
		Version:          Version,
		SupportedMajors:  SupportedMajors,
		KnownIntentKinds: KnownIntentKinds,
		MaxBatch:         maxBatch,
	}
}

// DecodeResult is what [DecodePlanRequest] returns alongside the request.
type DecodeResult struct {
	// Effective is the version the response must be stamped with.
	Effective ParsedVersion
	// UnknownFields is how many keys the sender used that this build ignores.
	// This is the skew telemetry: it is counted, not rejected, because
	// rejecting additive fields would make every rolling deployment an outage.
	UnknownFields int
	// UnknownFieldNames is a bounded sample of those keys, for logs.
	UnknownFieldNames []string
}

// maxUnknownFieldSamples bounds the log sample so a wildly mismatched peer
// cannot produce an unbounded log line.
const maxUnknownFieldSamples = 16

// DecodePlanRequest decodes and version-negotiates a batch.
//
// The decoding policy is the whole skew story in one function:
//
//  1. Version first. A different major is refused with [ErrVersionSkew] before
//     anything else is looked at, because fields may have been repurposed and
//     interpreting them under the wrong major produces wrong behaviour rather
//     than an error. The worldserver's response to a refusal is to stop calling
//     the brain and run tier-0 AI, which is ADR-0024 invariant 6.
//
//  2. Unknown fields are ignored and counted, never rejected. A newer
//     worldserver deployed ahead of the brain is the expected direction of
//     skew, and it must keep working.
//
//  3. Missing optional fields are absent, not zero, wherever the difference
//     matters -- which is why several snapshot scalars are pointers.
//
//  4. Structural nonsense (a string where an object belongs) is [ErrMalformed]
//     for the whole batch, because it means the two sides disagree about shape
//     rather than about content.
//
// maxBatch of zero means [DefaultMaxBatch].
func DecodePlanRequest(r io.Reader, maxBatch int) (*PlanRequest, DecodeResult, error) {
	if maxBatch <= 0 {
		maxBatch = DefaultMaxBatch
	}
	var res DecodeResult

	// Read once into a generic tree so unknown keys can be counted, then decode
	// again into the typed struct. Two passes over a batch is affordable next to
	// the planning it precedes, and it buys skew telemetry that a single strict
	// or single lenient decode cannot give.
	raw, err := io.ReadAll(r)
	if err != nil {
		// Both errors are wrapped, not just ErrMalformed. The reader handed to
		// us may be an http.MaxBytesReader, and the server distinguishes "body
		// too large" from "malformed" by errors.As on the cause - which finds
		// nothing if the cause is flattened into text by %v. The symptom of
		// getting this wrong is an over-sized request coming back as 400
		// "malformed JSON", sending the operator to hunt a bug in their encoder.
		return nil, res, fmt.Errorf("%w: reading body: %w", ErrMalformed, err)
	}
	var generic map[string]json.RawMessage
	if err := json.Unmarshal(raw, &generic); err != nil {
		return nil, res, fmt.Errorf("%w: body is not a JSON object: %v", ErrMalformed, err)
	}

	var versionField string
	if v, ok := generic["contract_version"]; ok {
		if err := json.Unmarshal(v, &versionField); err != nil {
			return nil, res, fmt.Errorf("%w: contract_version is not a string", ErrMalformed)
		}
	}
	effective, err := Negotiate(versionField)
	if err != nil {
		return nil, res, err
	}
	res.Effective = effective

	var req PlanRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		return nil, res, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if len(req.Snapshots) == 0 {
		return nil, res, fmt.Errorf("%w: batch has no snapshots", ErrMalformed)
	}
	if len(req.Snapshots) > maxBatch {
		return nil, res, fmt.Errorf("%w: batch of %d exceeds max %d", ErrBatchTooLarge, len(req.Snapshots), maxBatch)
	}

	countUnknown(generic, knownRequestFields, "", &res)
	var snapshotTrees []map[string]json.RawMessage
	if v, ok := generic["snapshots"]; ok {
		if err := json.Unmarshal(v, &snapshotTrees); err == nil {
			for idx, tree := range snapshotTrees {
				countUnknown(tree, knownSnapshotFields, "snapshots["+strconv.Itoa(idx)+"].", &res)
			}
		}
	}
	return &req, res, nil
}

var knownRequestFields = map[string]bool{
	"contract_version": true,
	"request_id":       true,
	"sent_at_ms":       true,
	"deadline_ms":      true,
	"snapshots":        true,
}

var knownSnapshotFields = map[string]bool{
	"bot": true, "char": true, "pos": true, "vitals": true,
	"surroundings": true, "quests": true, "pois": true,
	"last_outcome": true, "observed_at_ms": true, "hints": true,
}

func countUnknown(tree map[string]json.RawMessage, known map[string]bool, prefix string, res *DecodeResult) {
	for k := range tree {
		if known[k] {
			continue
		}
		res.UnknownFields++
		if len(res.UnknownFieldNames) < maxUnknownFieldSamples {
			res.UnknownFieldNames = append(res.UnknownFieldNames, prefix+k)
		}
	}
}

func errMalformedf(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrMalformed, fmt.Sprintf(format, args...))
}

func utoa(v uint64) string { return strconv.FormatUint(v, 10) }
