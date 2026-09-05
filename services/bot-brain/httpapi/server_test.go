package httpapi_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/contract"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/httpapi"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/metrics"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner"
	"github.com/Cilverkrow/twow-repo/services/bot-brain/planner/rule"
)

func newServer(t *testing.T, p planner.Planner) (*httpapi.Server, *metrics.Registry) {
	t.Helper()
	reg := metrics.New()
	if p == nil {
		p = rule.New(rule.Thresholds{})
	}
	srv := httpapi.New(httpapi.Options{
		Planner:         p,
		MaxBatch:        16,
		DefaultDeadline: time.Second,
		IntentTTL:       30 * time.Second,
		Metrics:         reg,
	})
	return srv, reg
}

func post(t *testing.T, srv *httpapi.Server, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/plan", strings.NewReader(body))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

func get(t *testing.T, srv *httpapi.Server, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

// batchBody renders a plan request for n bots.
func batchBody(version string, n int) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, `{"contract_version":%q,"request_id":"r-1","sent_at_ms":1700000000000,"deadline_ms":1000,"snapshots":[`, version)
	for i := 0; i < n; i++ {
		if i > 0 {
			sb.WriteByte(',')
		}
		fmt.Fprintf(&sb, `{
		  "bot":{"realm":1,"guid":%d},
		  "char":{"name":"B%d","level":20,"class":1,"race":1,"faction":"alliance","free_bag_slots":8},
		  "pos":{"map_id":0,"x":1,"y":2,"z":3},
		  "vitals":{"health_pct":100},
		  "surroundings":{"group_size":1},
		  "observed_at_ms":1699999999000,
		  "pois":[{"id":"p%d","kind":"grind_area","pos":{"map_id":0},"distance_yards":50}]
		}`, i+1, i+1, i+1)
	}
	sb.WriteString("]}")
	return sb.String()
}

func decodeResponse(t *testing.T, rec *httptest.ResponseRecorder) contract.PlanResponse {
	t.Helper()
	var resp contract.PlanResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding response: %v\nbody: %s", err, rec.Body.String())
	}
	return resp
}

func TestHealthAndReadiness(t *testing.T) {
	srv, _ := newServer(t, nil)

	if rec := get(t, srv, "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("/healthz = %d, want 200", rec.Code)
	}
	if rec := get(t, srv, "/readyz"); rec.Code != http.StatusOK {
		t.Fatalf("/readyz = %d, want 200", rec.Code)
	}

	srv.SetReady(false)
	if rec := get(t, srv, "/readyz"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("/readyz after SetReady(false) = %d, want 503", rec.Code)
	}
	// Liveness must stay up: a liveness probe that fails on a drainable
	// condition gets the container killed for something a restart cannot fix.
	if rec := get(t, srv, "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("/healthz during drain = %d, want 200", rec.Code)
	}
}

// Readiness must not depend on the LLM. A brain with a dead model still plans.
func TestReadinessIgnoresTheLLM(t *testing.T) {
	fb := &planner.Fallback{
		Primary:   deadPlanner{},
		Secondary: rule.New(rule.Thresholds{}),
		Timeout:   time.Millisecond,
	}
	srv, _ := newServer(t, fb)
	if rec := get(t, srv, "/readyz"); rec.Code != http.StatusOK {
		t.Fatalf("/readyz = %d, want 200 with a dead primary and a healthy fallback", rec.Code)
	}
}

type deadPlanner struct{}

func (deadPlanner) Name() string { return "dead" }
func (deadPlanner) Ready() bool  { return false }
func (deadPlanner) Plan(context.Context, planner.Request) ([]contract.Intent, error) {
	return nil, planner.ErrPlannerUnavailable
}

func TestContractEndpoint(t *testing.T) {
	srv, _ := newServer(t, nil)
	rec := get(t, srv, "/v1/contract")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	var info contract.ContractInfo
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Version != contract.Version {
		t.Errorf("version = %q, want %q", info.Version, contract.Version)
	}
	if info.MaxBatch != 16 {
		t.Errorf("max_batch = %d, want 16", info.MaxBatch)
	}
	if len(info.KnownIntentKinds) == 0 {
		t.Error("no intent kinds advertised; the C++ side cannot detect skew at startup")
	}
}

func TestBatchPlanning(t *testing.T) {
	tests := []struct {
		name        string
		n           int
		wantIntents int
	}{
		{name: "single bot", n: 1, wantIntents: 1},
		{name: "small batch", n: 5, wantIntents: 5},
		{name: "at the cap", n: 16, wantIntents: 16},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := newServer(t, nil)
			rec := post(t, srv, batchBody("1.0", tc.n))
			if rec.Code != http.StatusOK {
				t.Fatalf("code = %d, want 200: %s", rec.Code, rec.Body.String())
			}
			resp := decodeResponse(t, rec)
			if len(resp.Intents) != tc.wantIntents {
				t.Fatalf("got %d intents, want %d", len(resp.Intents), tc.wantIntents)
			}
			if resp.Stats.SnapshotsIn != tc.n {
				t.Errorf("stats.snapshots_in = %d, want %d", resp.Stats.SnapshotsIn, tc.n)
			}
			if resp.RequestID != "r-1" {
				t.Errorf("request_id = %q, want it echoed", resp.RequestID)
			}
			if len(resp.Errors) != 0 {
				t.Errorf("unexpected per-bot errors: %+v", resp.Errors)
			}
			// One intent per bot, addressed correctly, in batch order.
			for i, in := range resp.Intents {
				if in.Bot.GUID != uint64(i+1) {
					t.Fatalf("intent %d addressed to guid %d, want %d", i, in.Bot.GUID, i+1)
				}
				if in.ExpiresAtMS != 1_700_000_030_000 {
					t.Errorf("intent %d expiry = %d, want the server clock plus TTL", i, in.ExpiresAtMS)
				}
			}
		})
	}
}

// One bad snapshot must cost only its own bot. At 1000 bots per batch, failing
// the whole call over one entry would be a self-inflicted outage.
func TestOneMalformedSnapshotDoesNotFailTheBatch(t *testing.T) {
	body := `{"contract_version":"1.0","sent_at_ms":1700000000000,"snapshots":[
	  {"bot":{"realm":1,"guid":1},"char":{"level":20},"vitals":{"health_pct":100},"surroundings":{"group_size":1}},
	  {"bot":{"realm":1,"guid":0},"char":{"level":20},"vitals":{"health_pct":100},"surroundings":{"group_size":1}},
	  {"bot":{"realm":1,"guid":3},"char":{"level":20},"vitals":{"health_pct":100},"surroundings":{"group_size":1}}
	]}`
	srv, reg := newServer(t, nil)
	rec := post(t, srv, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200; one bad snapshot must not fail the batch", rec.Code)
	}
	resp := decodeResponse(t, rec)
	if len(resp.Intents) != 2 {
		t.Fatalf("got %d intents, want 2 (the two valid bots)", len(resp.Intents))
	}
	if len(resp.Errors) != 1 || resp.Errors[0].Code != contract.CodeMalformed {
		t.Fatalf("errors = %+v, want one malformed entry", resp.Errors)
	}
	if reg.Value(httpapi.MetricPlanErrors, "code", contract.CodeMalformed) != 1 {
		t.Errorf("the malformed snapshot was not counted:\n%s", reg.String())
	}
}

func TestVersionSkewHandling(t *testing.T) {
	tests := []struct {
		name       string
		version    string
		wantStatus int
		wantStamp  string
		wantCode   string
	}{
		// Both stamps are contract.Version rather than a literal: this test asserts
		// the negotiation rule, not a particular version number. Hardcoding "1.0"
		// meant a legitimate minor bump broke a test that had nothing to do with
		// the change - which is how people learn to edit tests instead of reading
		// them.
		{name: "exact", version: contract.Version, wantStatus: http.StatusOK, wantStamp: contract.Version},
		{
			// A peer ahead of us on the minor is served, and the response is stamped
			// with OUR version - we cannot promise a minor we do not implement.
			// 1.99 rather than 1.9 so this stays 'newer' as our own minor climbs.
			name: "newer minor peer is served", version: "1.99",
			wantStatus: http.StatusOK, wantStamp: contract.Version,
		},
		{
			name: "different major is refused", version: "2.0",
			wantStatus: http.StatusConflict, wantCode: contract.CodeVersionSkew,
		},
		{
			name: "missing version is refused", version: "",
			wantStatus: http.StatusConflict, wantCode: contract.CodeVersionSkew,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, reg := newServer(t, nil)
			rec := post(t, srv, batchBody(tc.version, 1))
			if rec.Code != tc.wantStatus {
				t.Fatalf("code = %d, want %d: %s", rec.Code, tc.wantStatus, rec.Body.String())
			}
			if tc.wantStamp != "" {
				resp := decodeResponse(t, rec)
				if resp.ContractVersion != tc.wantStamp {
					t.Errorf("response stamped %q, want %q", resp.ContractVersion, tc.wantStamp)
				}
			}
			if tc.wantCode != "" {
				var body struct {
					Code            string `json:"code"`
					SupportedMajors []int  `json:"supported_majors"`
				}
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if body.Code != tc.wantCode {
					t.Errorf("code = %q, want %q", body.Code, tc.wantCode)
				}
				if len(body.SupportedMajors) == 0 {
					t.Error("the refusal did not say what majors are supported, so the peer cannot act on it")
				}
				if reg.Value(httpapi.MetricVersionSkew) != 1 {
					t.Errorf("version skew was not counted:\n%s", reg.String())
				}
			}
		})
	}
}

// A newer worldserver sending fields this build ignores is the normal shape of
// a rolling deploy. It must be served, and it must be visible in metrics.
func TestUnknownFieldsAreServedAndCounted(t *testing.T) {
	body := `{"contract_version":"1.3","sent_at_ms":1700000000000,"future_knob":true,"snapshots":[
	  {"bot":{"realm":1,"guid":1},"char":{"level":20},"vitals":{"health_pct":100},
	   "surroundings":{"group_size":1},"threat_table":[1,2,3]}
	]}`
	srv, reg := newServer(t, nil)
	rec := post(t, srv, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	resp := decodeResponse(t, rec)
	if resp.Stats.UnknownFields != 2 {
		t.Fatalf("stats.unknown_fields = %d, want 2", resp.Stats.UnknownFields)
	}
	if reg.Value(httpapi.MetricUnknownFields) != 2 {
		t.Errorf("unknown fields not counted:\n%s", reg.String())
	}
	if len(resp.Intents) != 1 {
		t.Errorf("got %d intents, want 1; a rolling deploy must not stop planning", len(resp.Intents))
	}
}

func TestOversizedBatchRejected(t *testing.T) {
	srv, _ := newServer(t, nil)
	rec := post(t, srv, batchBody("1.0", 17))
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("code = %d, want 413", rec.Code)
	}
}

func TestMalformedBodyRejected(t *testing.T) {
	srv, _ := newServer(t, nil)
	for _, body := range []string{``, `not json`, `{"contract_version":"1.0"}`} {
		rec := post(t, srv, body)
		if rec.Code != http.StatusBadRequest && rec.Code != http.StatusConflict {
			t.Errorf("body %q gave %d, want 400 or 409", body, rec.Code)
		}
	}
}

// The transport is the last line of defence for ADR-0024 invariant 1: a planner
// bug must never deliver an intent to a bot the server did not ask about.
func TestIntentsForUnaskedBotsAreDropped(t *testing.T) {
	srv, reg := newServer(t, &rogue{})
	rec := post(t, srv, batchBody("1.0", 2))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	resp := decodeResponse(t, rec)
	for _, in := range resp.Intents {
		if in.Bot.GUID == 999999 {
			t.Fatalf("an intent for a bot outside the batch was returned: %+v", in)
		}
	}
	if reg.Value(httpapi.MetricDroppedIntents, "reason", "unasked_bot") != 1 {
		t.Errorf("the stray intent was not counted:\n%s", reg.String())
	}
}

// rogue answers correctly for the batch and also for a bot nobody asked about.
type rogue struct{}

func (*rogue) Name() string { return "rogue" }
func (*rogue) Ready() bool  { return true }
func (*rogue) Plan(_ context.Context, req planner.Request) ([]contract.Intent, error) {
	out := make([]contract.Intent, 0, len(req.Snapshots)+1)
	for _, s := range req.Snapshots {
		out = append(out, contract.Idle(s.Bot, planner.NewIntentID(), "rogue", "ok"))
	}
	out = append(out, contract.Idle(contract.BotID{Realm: 9, GUID: 999999},
		planner.NewIntentID(), "rogue", "a bot nobody asked about"))
	return out, nil
}

// The end-to-end fallback path: a slow LLM must not stop a batch from being
// answered, and the response must say the fallback was used.
func TestSlowPrimaryFallsBackEndToEnd(t *testing.T) {
	fb := &planner.Fallback{
		Primary:   slowPlanner{delay: 5 * time.Second},
		Secondary: rule.New(rule.Thresholds{}),
		Timeout:   20 * time.Millisecond,
	}
	srv, reg := newServer(t, fb)

	start := time.Now()
	rec := post(t, srv, batchBody("1.0", 8))
	elapsed := time.Since(start)

	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	resp := decodeResponse(t, rec)
	if len(resp.Intents) != 8 {
		t.Fatalf("got %d intents, want 8; a slow model must never cost a bot its plan", len(resp.Intents))
	}
	if resp.Stats.FallbackUsed != 8 {
		t.Errorf("stats.fallback_used = %d, want 8", resp.Stats.FallbackUsed)
	}
	if elapsed > 2*time.Second {
		t.Errorf("request took %s; the primary timeout should have bounded it near 20ms", elapsed)
	}
	if reg.Value(httpapi.MetricFallbackIntents) != 8 {
		t.Errorf("fallback intents not counted:\n%s", reg.String())
	}
	for _, in := range resp.Intents {
		if in.Source != "fallback" {
			t.Errorf("intent source = %q, want fallback", in.Source)
		}
	}
}

type slowPlanner struct{ delay time.Duration }

func (slowPlanner) Name() string { return "slow" }
func (slowPlanner) Ready() bool  { return true }
func (s slowPlanner) Plan(ctx context.Context, _ planner.Request) ([]contract.Intent, error) {
	select {
	case <-time.After(s.delay):
		return nil, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// A bot that gets no intent at all is reported rather than silently missing, so
// the caller can see the gap instead of inferring it.
func TestUnplannedBotsAreReported(t *testing.T) {
	srv, _ := newServer(t, silentPlanner{})
	rec := post(t, srv, batchBody("1.0", 3))
	resp := decodeResponse(t, rec)
	if len(resp.Intents) != 0 {
		t.Fatalf("got %d intents, want 0", len(resp.Intents))
	}
	if len(resp.Errors) != 3 {
		t.Fatalf("got %d errors, want 3", len(resp.Errors))
	}
	for _, e := range resp.Errors {
		if e.Code != contract.CodeBotUnplannable {
			t.Errorf("code = %q, want %q", e.Code, contract.CodeBotUnplannable)
		}
	}
}

type silentPlanner struct{}

func (silentPlanner) Name() string { return "silent" }
func (silentPlanner) Ready() bool  { return true }
func (silentPlanner) Plan(context.Context, planner.Request) ([]contract.Intent, error) {
	return nil, nil
}

func TestMetricsEndpoint(t *testing.T) {
	srv, _ := newServer(t, nil)
	post(t, srv, batchBody("1.0", 3))

	rec := get(t, srv, "/metrics")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Errorf("content type = %q, want Prometheus text exposition", ct)
	}
	body := rec.Body.String()
	for _, want := range []string{
		"# TYPE " + httpapi.MetricPlanRequests + " counter",
		httpapi.MetricPlanSnapshots + " 3",
		"# TYPE " + httpapi.MetricPlanSeconds + " histogram",
		httpapi.MetricPlanSeconds + "_count 1",
		httpapi.MetricReady + " 1",
		httpapi.MetricPlanIntents + `{source="rule"} 3`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics output is missing %q:\n%s", want, body)
		}
	}
}

// A thousand-bot batch is the load this design exists for.
func TestThousandBotBatch(t *testing.T) {
	reg := metrics.New()
	srv := httpapi.New(httpapi.Options{
		Planner:         rule.New(rule.Thresholds{}),
		MaxBatch:        2048,
		DefaultDeadline: 5 * time.Second,
		IntentTTL:       30 * time.Second,
		Metrics:         reg,
	})
	rec := post(t, srv, batchBody("1.0", 1000))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	resp := decodeResponse(t, rec)
	if len(resp.Intents) != 1000 {
		t.Fatalf("got %d intents, want 1000", len(resp.Intents))
	}
	if len(resp.Errors) != 0 {
		t.Fatalf("unexpected errors: %+v", resp.Errors[:1])
	}
}

func TestWrongMethodAndPath(t *testing.T) {
	srv, _ := newServer(t, nil)
	req := httptest.NewRequest(http.MethodGet, "/v1/plan", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Error("GET /v1/plan should not succeed")
	}
	if rec := get(t, srv, "/v2/plan"); rec.Code != http.StatusNotFound {
		t.Errorf("unknown path = %d, want 404", rec.Code)
	}
}

// The body cap must bind BEFORE the JSON is decoded.
//
// MaxBatch is not a substitute: the decoder enforces it, and the decoder does
// not run until the whole body is in memory. Since /v1/plan is unauthenticated
// by design, without this cap a single POST of arbitrary length is read in full
// and the service is one curl away from being OOM-killed.
func TestOversizedBodyIsRejected(t *testing.T) {
	reg := metrics.New()
	srv := httpapi.New(httpapi.Options{
		Planner:         rule.New(rule.Thresholds{}),
		MaxBatch:        16,
		MaxBodyBytes:    512,
		DefaultDeadline: time.Second,
		IntentTTL:       30 * time.Second,
		Metrics:         reg,
	})

	// Deliberately ONE snapshot, so MaxBatch cannot be what rejects it: the
	// only thing over the limit here is the number of bytes. Padding rides in
	// an unknown field, which the decoder tolerates by design.
	body := `{"contract_version":"` + contract.Version + `","request_id":"r1","snapshots":[{"bot":{"realm":1,"guid":1}}],"pad":"` +
		strings.Repeat("x", 4096) + `"}`

	rec := post(t, srv, body)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413; a %d-byte body got past a 512-byte cap", rec.Code, len(body))
	}
	// The code matters as much as the status: the C++ client keys its
	// batch-halving on it, and a "malformed" would send it looking for an
	// encoder bug instead.
	var resp struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	if resp.Code != contract.CodeBatchTooLarge {
		t.Errorf("code = %q, want %q", resp.Code, contract.CodeBatchTooLarge)
	}
}

// A body under the cap is unaffected: the limit must not become a second,
// invisible batch limit.
func TestBodyUnderCapIsAccepted(t *testing.T) {
	reg := metrics.New()
	srv := httpapi.New(httpapi.Options{
		Planner:         rule.New(rule.Thresholds{}),
		MaxBatch:        16,
		MaxBodyBytes:    512,
		DefaultDeadline: time.Second,
		IntentTTL:       30 * time.Second,
		Metrics:         reg,
	})
	rec := post(t, srv, `{"contract_version":"`+contract.Version+`","request_id":"r1","snapshots":[{"bot":{"realm":1,"guid":1}}]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d (%s), want 200", rec.Code, rec.Body.String())
	}
}

// Zero means "use the contract default", not "read nothing".
func TestZeroMaxBodyBytesMeansTheDefault(t *testing.T) {
	srv, _ := newServer(t, nil) // newServer leaves MaxBodyBytes unset
	rec := post(t, srv, `{"contract_version":"`+contract.Version+`","request_id":"r1","snapshots":[{"bot":{"realm":1,"guid":1}}]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d (%s); an unset MaxBodyBytes must not reject a normal request", rec.Code, rec.Body.String())
	}
}
