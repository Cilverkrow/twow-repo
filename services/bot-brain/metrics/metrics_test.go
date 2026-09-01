package metrics_test

import (
	"strings"
	"sync"
	"testing"

	"github.com/Cilverkrow/twow-repo/services/bot-brain/metrics"
)

func TestExposition(t *testing.T) {
	r := metrics.New()
	r.Describe("botbrain_test_total", "A test counter.")
	r.Inc("botbrain_test_total", 1, "code", "ok")
	r.Inc("botbrain_test_total", 2, "code", "ok")
	r.Inc("botbrain_test_total", 5, "code", "bad")
	r.SetGauge("botbrain_test_gauge", 1)
	r.Observe("botbrain_test_seconds", 0.03)

	out := r.String()
	for _, want := range []string{
		"# HELP botbrain_test_total A test counter.",
		"# TYPE botbrain_test_total counter",
		`botbrain_test_total{code="bad"} 5`,
		`botbrain_test_total{code="ok"} 3`,
		"# TYPE botbrain_test_gauge gauge",
		"botbrain_test_gauge 1",
		"# TYPE botbrain_test_seconds histogram",
		`botbrain_test_seconds_bucket{le="0.05"} 1`,
		`botbrain_test_seconds_bucket{le="0.01"} 0`,
		"botbrain_test_seconds_count 1",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

// Output must be byte-stable so a scrape is diffable and testable.
func TestExpositionIsStable(t *testing.T) {
	build := func() string {
		r := metrics.New()
		r.Inc("a_total", 1, "z", "1", "a", "2")
		r.Inc("b_total", 1)
		r.SetGauge("c", 3)
		return r.String()
	}
	first := build()
	for i := 0; i < 20; i++ {
		if got := build(); got != first {
			t.Fatalf("exposition differed between runs:\n%s\nvs\n%s", first, got)
		}
	}
}

// Label order must not split a counter in two.
func TestLabelOrderIsCanonical(t *testing.T) {
	r := metrics.New()
	r.Inc("x_total", 1, "a", "1", "b", "2")
	r.Inc("x_total", 1, "b", "2", "a", "1")
	if got := r.Value("x_total", "a", "1", "b", "2"); got != 2 {
		t.Fatalf("value = %v, want 2; label order must not create a second series:\n%s", got, r.String())
	}
}

func TestLabelEscaping(t *testing.T) {
	r := metrics.New()
	r.Inc("y_total", 1, "msg", `he said "hi"`)
	out := r.String()
	if !strings.Contains(out, `msg="he said \"hi\""`) {
		t.Fatalf("quotes were not escaped:\n%s", out)
	}
}

// A metrics bug must never take down a planning request.
func TestOddLabelsDoNotPanic(t *testing.T) {
	r := metrics.New()
	r.Inc("z_total", 1, "lonely")
	if got := r.Value("z_total"); got != 1 {
		t.Fatalf("value = %v, want 1 (odd labels are ignored, not fatal)", got)
	}
}

func TestConcurrentUse(t *testing.T) {
	r := metrics.New()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				r.Inc("conc_total", 1, "w", "x")
				r.SetGauge("conc_gauge", 1)
				r.Observe("conc_seconds", 0.01)
				_ = r.String()
			}
		}()
	}
	wg.Wait()
	if got := r.Value("conc_total", "w", "x"); got != 5000 {
		t.Fatalf("counter = %v, want 5000", got)
	}
}
