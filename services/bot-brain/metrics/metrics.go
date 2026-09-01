// Package metrics is a minimal Prometheus text-exposition registry.
//
// It is hand-written rather than client_golang on purpose: this module has zero
// external dependencies, so it builds and tests on a machine with no module
// proxy and no network. That is a deliberate trade -- no histograms with proper
// exemplars, no collectors -- and if this service ever needs real histogram
// semantics, swapping in client_golang is a contained change behind this
// package's API.
//
// Everything here is safe for concurrent use.
package metrics

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// Registry holds counters and gauges.
type Registry struct {
	mu       sync.RWMutex
	counters map[string]*series
	gauges   map[string]*series
	hists    map[string]*histogram
	help     map[string]string
}

type series struct {
	mu     sync.Mutex
	values map[string]float64 // label-string -> value
}

// New returns an empty registry.
func New() *Registry {
	return &Registry{
		counters: map[string]*series{},
		gauges:   map[string]*series{},
		hists:    map[string]*histogram{},
		help:     map[string]string{},
	}
}

// Describe attaches HELP text to a metric name.
func (r *Registry) Describe(name, help string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.help[name] = help
}

// Inc adds delta to a counter. Labels are given as alternating key/value pairs;
// an odd count is ignored rather than panicking, because a metrics bug must
// never take down a planning request.
func (r *Registry) Inc(name string, delta float64, labels ...string) {
	r.seriesFor(&r.counters, name).add(labelKey(labels), delta)
}

// SetGauge sets a gauge value.
func (r *Registry) SetGauge(name string, v float64, labels ...string) {
	r.seriesFor(&r.gauges, name).set(labelKey(labels), v)
}

// Observe records a value into a fixed-bucket histogram. Buckets are seconds
// and are fixed at construction of the histogram on first use.
func (r *Registry) Observe(name string, v float64) {
	r.mu.Lock()
	h, ok := r.hists[name]
	if !ok {
		h = newHistogram()
		r.hists[name] = h
	}
	r.mu.Unlock()
	h.observe(v)
}

func (r *Registry) seriesFor(m *map[string]*series, name string) *series {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := (*m)[name]
	if !ok {
		s = &series{values: map[string]float64{}}
		(*m)[name] = s
	}
	return s
}

func (s *series) add(key string, delta float64) {
	s.mu.Lock()
	s.values[key] += delta
	s.mu.Unlock()
}

func (s *series) set(key string, v float64) {
	s.mu.Lock()
	s.values[key] = v
	s.mu.Unlock()
}

func (s *series) snapshot() map[string]float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]float64, len(s.values))
	for k, v := range s.values {
		out[k] = v
	}
	return out
}

// Value reads one series value. Present for tests; it is not part of the
// exposition path.
func (r *Registry) Value(name string, labels ...string) float64 {
	r.mu.RLock()
	c, cok := r.counters[name]
	g, gok := r.gauges[name]
	r.mu.RUnlock()
	key := labelKey(labels)
	if cok {
		if v, ok := c.snapshot()[key]; ok {
			return v
		}
	}
	if gok {
		if v, ok := g.snapshot()[key]; ok {
			return v
		}
	}
	return 0
}

var defaultBuckets = []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

type histogram struct {
	mu     sync.Mutex
	counts []uint64
	sum    float64
	total  uint64
}

func newHistogram() *histogram {
	return &histogram{counts: make([]uint64, len(defaultBuckets))}
}

func (h *histogram) observe(v float64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sum += v
	h.total++
	for i, b := range defaultBuckets {
		if v <= b {
			h.counts[i]++
		}
	}
}

// labelKey renders alternating key/value pairs into a canonical, sorted label
// string. Sorting matters: two calls with the same labels in different orders
// must land on the same series, or a counter silently splits in two.
func labelKey(labels []string) string {
	if len(labels) < 2 {
		return ""
	}
	pairs := make([]string, 0, len(labels)/2)
	for i := 0; i+1 < len(labels); i += 2 {
		pairs = append(pairs, labels[i]+"=\""+escape(labels[i+1])+"\"")
	}
	sort.Strings(pairs)
	return strings.Join(pairs, ",")
}

func escape(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\"", "\\\"")
	s = strings.ReplaceAll(s, "\n", "\\n")
	return s
}

// Write renders the registry in Prometheus text exposition format v0.0.4.
// Output is sorted so that a scrape is byte-stable, which makes it testable.
func (r *Registry) Write(w *strings.Builder) {
	r.mu.RLock()
	counters := copyNames(r.counters)
	gauges := copyNames(r.gauges)
	hists := make([]string, 0, len(r.hists))
	for k := range r.hists {
		hists = append(hists, k)
	}
	sort.Strings(hists)
	help := make(map[string]string, len(r.help))
	for k, v := range r.help {
		help[k] = v
	}
	histRefs := make(map[string]*histogram, len(r.hists))
	for k, v := range r.hists {
		histRefs[k] = v
	}
	counterRefs := make(map[string]*series, len(r.counters))
	for k, v := range r.counters {
		counterRefs[k] = v
	}
	gaugeRefs := make(map[string]*series, len(r.gauges))
	for k, v := range r.gauges {
		gaugeRefs[k] = v
	}
	r.mu.RUnlock()

	writeSeries(w, counters, counterRefs, help, "counter")
	writeSeries(w, gauges, gaugeRefs, help, "gauge")

	for _, name := range hists {
		if h, ok := help[name]; ok {
			fmt.Fprintf(w, "# HELP %s %s\n", name, h)
		}
		fmt.Fprintf(w, "# TYPE %s histogram\n", name)
		hist := histRefs[name]
		hist.mu.Lock()
		for i, b := range defaultBuckets {
			fmt.Fprintf(w, "%s_bucket{le=\"%s\"} %d\n", name, strconv.FormatFloat(b, 'g', -1, 64), hist.counts[i])
		}
		fmt.Fprintf(w, "%s_bucket{le=\"+Inf\"} %d\n", name, hist.total)
		fmt.Fprintf(w, "%s_sum %s\n", name, strconv.FormatFloat(hist.sum, 'g', -1, 64))
		fmt.Fprintf(w, "%s_count %d\n", name, hist.total)
		hist.mu.Unlock()
	}
}

func writeSeries(w *strings.Builder, names []string, refs map[string]*series, help map[string]string, typ string) {
	for _, name := range names {
		if h, ok := help[name]; ok {
			fmt.Fprintf(w, "# HELP %s %s\n", name, h)
		}
		fmt.Fprintf(w, "# TYPE %s %s\n", name, typ)
		snap := refs[name].snapshot()
		keys := make([]string, 0, len(snap))
		for k := range snap {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if k == "" {
				fmt.Fprintf(w, "%s %s\n", name, strconv.FormatFloat(snap[k], 'g', -1, 64))
			} else {
				fmt.Fprintf(w, "%s{%s} %s\n", name, k, strconv.FormatFloat(snap[k], 'g', -1, 64))
			}
		}
	}
}

func copyNames(m map[string]*series) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// String renders the whole registry.
func (r *Registry) String() string {
	var sb strings.Builder
	r.Write(&sb)
	return sb.String()
}
