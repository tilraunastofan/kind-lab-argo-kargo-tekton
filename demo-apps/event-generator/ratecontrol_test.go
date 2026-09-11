// demo-apps/event-generator/ratecontrol_test.go
package main

import (
	"math/rand"
	"testing"
	"time"
)

func TestNewRateControllerStartsAtBaseline(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	if rc.IsHighLoad() {
		t.Fatal("expected baseline (not high load) immediately after construction")
	}
}

func TestBaselineIntervalIsWithinRange(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 1000; i++ {
		d := rc.NextInterval(rng)
		if d < 200*time.Millisecond || d >= 1000*time.Millisecond {
			t.Fatalf("baseline interval %v out of [200ms, 1000ms) range", d)
		}
	}
}

func TestTriggerHighLoadSwitchesRateAndExpires(t *testing.T) {
	rc := NewRateController(50 * time.Millisecond)
	rc.TriggerHighLoad()
	if !rc.IsHighLoad() {
		t.Fatal("expected high load immediately after trigger")
	}
	rng := rand.New(rand.NewSource(1))
	d := rc.NextInterval(rng)
	if d < time.Millisecond || d >= 2*time.Millisecond {
		t.Fatalf("high-load interval %v out of [1ms, 2ms) range", d)
	}
	time.Sleep(80 * time.Millisecond)
	if rc.IsHighLoad() {
		t.Fatal("expected high load to have expired after its duration elapsed")
	}
}

func TestTriggerHighLoadExtendsRatherThanStacks(t *testing.T) {
	rc := NewRateController(100 * time.Millisecond)
	rc.TriggerHighLoad()
	time.Sleep(70 * time.Millisecond)
	rc.TriggerHighLoad() // should reset the 100ms window from now, not add to it
	time.Sleep(70 * time.Millisecond)
	if !rc.IsHighLoad() {
		t.Fatal("expected second trigger to have extended the high-load window past 140ms total")
	}
	time.Sleep(60 * time.Millisecond) // total 140ms since second trigger > 100ms duration
	if rc.IsHighLoad() {
		t.Fatal("expected high load to have expired 100ms after the last trigger")
	}
}
