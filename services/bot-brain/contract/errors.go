package contract

import "errors"

// Sentinel errors that the transport layer maps to machine-readable codes. The
// C++ side switches on the code string, never on the message text.
var (
	// ErrVersionSkew: the peer speaks a contract major this build cannot serve,
	// or sent no version at all. The worldserver's correct response is to stop
	// calling the brain and run tier 0 in-core AI (ADR-0024 invariant 6, fail
	// closed to core behaviour rather than to wrong behaviour).
	ErrVersionSkew = errors.New("contract version skew")

	// ErrMalformed: the envelope did not decode, or a required field was absent.
	ErrMalformed = errors.New("malformed request")

	// ErrBatchTooLarge: more snapshots in one call than this build will accept.
	ErrBatchTooLarge = errors.New("batch too large")
)

// Error codes carried in [PlanError.Code] and in the top-level error envelope.
// These are stable strings and are part of the contract: adding one is a MINOR
// change, changing the meaning of one is a MAJOR change.
const (
	CodeVersionSkew    = "version_skew"
	CodeMalformed      = "malformed"
	CodeBatchTooLarge  = "batch_too_large"
	CodeBotUnplannable = "bot_unplannable" // per-bot: the planner had nothing safe to say.
	CodeBotTimeout     = "bot_timeout"     // per-bot: deadline hit before any planner answered.
	CodeBotInternal    = "bot_internal"    // per-bot: planner bug. Never fails the batch.
	CodeOverloaded     = "overloaded"      // the service shed this batch on purpose.
)
