package main

import (
	"math/rand"
	"testing"
)

func TestGenerateEventProducesValidEventType(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	valid := map[string]bool{"page_view": true, "click": true, "purchase": true, "error": true}
	for i := 0; i < 1000; i++ {
		e := GenerateEvent(rng)
		if !valid[e.EventType] {
			t.Fatalf("unexpected event type %q", e.EventType)
		}
		if e.Timestamp.IsZero() {
			t.Fatal("expected non-zero timestamp")
		}
	}
}
