// demo-apps/event-generator/ratecontrol.go
package main

import (
	"math/rand"
	"sync"
	"time"
)

// RateController tracks whether the background inserter (see main.go's
// runInserter) should currently be running at baseline (200-1000ms between
// inserts) or high-load (1-2ms between inserts, i.e. ~500-1000/sec) pace,
// and for how much longer.
//
// This struct is read from two different goroutines: the background
// inserter loop calls IsHighLoad()/NextInterval() every iteration, and an
// HTTP handler goroutine calls TriggerHighLoad() whenever a request hits
// POST /api/load/high. Go's net/http server spins up a new goroutine per
// request, so without the mutex below, one goroutine writing `deadline`
// while another reads it would be a data race — exactly the kind of bug
// `go test -race` (Task 1 Step 5's test run should ideally include `-race`)
// is designed to catch.
type RateController struct {
	mu       sync.Mutex
	duration time.Duration
	// deadline is the wall-clock time the current high-load window ends.
	// The Go zero value for time.Time (year 1, not "now") doubles as our
	// "not currently in high load" sentinel, checked via IsZero() below —
	// a common Go idiom for "optional" values on types that don't have a
	// built-in nil, since time.Time is a struct, not a pointer.
	deadline time.Time
}

// NewRateController is a constructor function — Go has no class
// constructors, so exported New*() functions returning a pointer to the
// struct are the idiomatic way to build one with its fields set correctly.
func NewRateController(highLoadDuration time.Duration) *RateController {
	return &RateController{duration: highLoadDuration}
}

// TriggerHighLoad starts (or extends) a high-load window ending `duration`
// from now. A concurrent call while already in high load resets the window
// forward rather than stacking additional time on top of it — this is what
// the spec means by "concurrent triggers extend/reset the duration rather
// than stacking multiple ramps": there's no queue or counter of pending
// ramps, just one deadline that keeps getting pushed out.
func (rc *RateController) TriggerHighLoad() {
	rc.mu.Lock()
	defer rc.mu.Unlock() // defer guarantees the unlock runs even on a panic
	rc.deadline = time.Now().Add(rc.duration)
}

// IsHighLoad reports whether we're still inside the high-load window. Note
// this is also what /healthz-adjacent "is the app doing something unusual"
// state would look like if we ever wanted to expose it — Kubernetes has no
// built-in concept of "this pod is intentionally under synthetic load", so
// that's just ordinary application state, not something the platform knows
// about.
func (rc *RateController) IsHighLoad() bool {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	return !rc.deadline.IsZero() && time.Now().Before(rc.deadline)
}

// NextInterval returns how long the background loop should sleep before its
// next insert, given the controller's current state. Taking `rng` as a
// parameter (instead of using the global math/rand functions) is what makes
// this function deterministically testable: the tests below seed their own
// *rand.Rand with a fixed source, so results are reproducible instead of
// depending on real wall-clock-seeded randomness.
func (rc *RateController) NextInterval(rng *rand.Rand) time.Duration {
	if rc.IsHighLoad() {
		// 1-2ms between inserts ≈ 500-1000 inserts/sec, matching the
		// spec's "ramps the insert rate to ~500-1000 events/sec".
		return time.Duration(rng.Int63n(int64(time.Millisecond))) + time.Millisecond
	}
	// 200-1000ms between inserts, per the spec's baseline background rate.
	return time.Duration(rng.Int63n(int64(800*time.Millisecond))) + 200*time.Millisecond
}
