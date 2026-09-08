package llm

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

// StatusError is a non-200 from the provider, carrying enough for a caller to
// decide whether trying again is sensible.
//
// It exists because "should this be retried" is not the planner's decision. A
// call racing a tick must never retry -- the fallback needs the remaining budget
// -- while a call made between ticks can afford to wait out a rate limit. The
// planner reports what happened; whoever owns the time decides what to do.
type StatusError struct {
	// Code is the HTTP status.
	Code int
	// RetryAfter is the provider's own instruction, zero when it gave none.
	// Honoured rather than guessed at: a backoff of our own choosing that is
	// shorter than what the provider asked for is how a rate limit becomes a
	// ban.
	RetryAfter time.Duration
	// Body is a truncated copy, for the log.
	Body string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("llm: endpoint returned %d: %s", e.Code, e.Body)
}

// Retryable reports whether trying the same request again could plausibly
// succeed.
//
// 429 is the rate limit and 5xx is the provider having a bad moment; both pass.
// 4xx other than 429 does not: a malformed request, a bad key or a model that
// does not exist will fail identically forever, and retrying those turns one
// mistake into a stream of them -- billed, in the cloud case.
func (e *StatusError) Retryable() bool {
	if e == nil {
		return false
	}
	return e.Code == http.StatusTooManyRequests || (e.Code >= 500 && e.Code <= 599)
}

// Retryable reports whether err is a retryable provider failure.
//
// Transport errors are deliberately NOT retryable here. A connection that was
// refused or timed out has already consumed the caller's patience, and the next
// round will try again anyway -- retrying inside one round would just spend the
// same budget faster.
func Retryable(err error) bool {
	var se *StatusError
	if errors.As(err, &se) {
		return se.Retryable()
	}
	return false
}

// RetryAfter is the provider's requested wait, or zero.
func RetryAfter(err error) time.Duration {
	var se *StatusError
	if errors.As(err, &se) {
		return se.RetryAfter
	}
	return 0
}

// retryAfter parses the header, which RFC 9110 allows to be either a count of
// seconds or an HTTP date. Both are handled because providers use both.
func retryAfter(v string) time.Duration {
	if v == "" {
		return 0
	}
	if secs, err := strconv.Atoi(v); err == nil {
		if secs < 0 {
			return 0
		}
		return time.Duration(secs) * time.Second
	}
	if when, err := http.ParseTime(v); err == nil {
		if d := time.Until(when); d > 0 {
			return d
		}
	}
	// Unparseable is not zero-with-confidence: it means the provider asked for
	// something we did not understand, and treating that as "retry immediately"
	// is the worst available reading.
	return defaultRetryAfter
}

// defaultRetryAfter is used when a provider asks us to wait but not how long.
const defaultRetryAfter = 5 * time.Second
