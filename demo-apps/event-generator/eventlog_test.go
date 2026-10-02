package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestEventLogKeepsOnlyNewestWhenFull(t *testing.T) {
	l := NewEventLog()
	for i := 0; i < eventLogCapacity+50; i++ {
		l.Add(Event{EventType: "click", UserID: uint32(i)})
	}
	events, stats := l.Snapshot(0)
	if len(events) != eventLogCapacity {
		t.Fatalf("expected %d events, got %d", eventLogCapacity, len(events))
	}
	if events[0].UserID != uint32(eventLogCapacity+49) || events[len(events)-1].UserID != 50 {
		t.Fatalf("wrong order/window: first=%d last=%d", events[0].UserID, events[len(events)-1].UserID)
	}
	if stats.Total != uint64(eventLogCapacity+50) {
		t.Fatalf("total should count evicted events too, got %d", stats.Total)
	}
}

func TestEventLogRateUsesRecentWindowOnly(t *testing.T) {
	l := NewEventLog()
	now := time.Unix(1_000_000, 0)
	l.now = func() time.Time { return now }
	for i := 0; i < 50; i++ { // 50 events "now"
		l.Add(Event{EventType: "click"})
	}
	now = now.Add(30 * time.Second) // ...which then age out of the 10s window
	for i := 0; i < 20; i++ {
		l.Add(Event{EventType: "click"})
	}
	_, stats := l.Snapshot(1)
	if stats.RatePerSec != 2 {
		t.Fatalf("expected 2/s (20 events over 10s), got %v", stats.RatePerSec)
	}
}

type failingInserter struct{}

func (failingInserter) InsertEvent(context.Context, Event) error { return errors.New("boom") }

func TestRecordingInserterCountsFailuresWithoutRecordingEvents(t *testing.T) {
	l := NewEventLog()
	r := recordingInserter{inner: failingInserter{}, log: l}
	if err := r.InsertEvent(context.Background(), Event{EventType: "click"}); err == nil {
		t.Fatal("expected error to propagate")
	}
	events, stats := l.Snapshot(0)
	if len(events) != 0 || stats.Failed != 1 || stats.Total != 0 {
		t.Fatalf("events=%d stats=%+v", len(events), stats)
	}
}
