// demo-apps/event-generator/eventlog.go
package main

import (
	"context"
	"sync"
	"time"
)

const (
	eventLogCapacity = 200 // newest events kept for the UI sample
	rateWindowSecs   = 10  // window the reported insert rate is averaged over
	bucketCount      = 60  // per-second counters kept (must exceed rateWindowSecs)
)

// EventLog remembers the most recent successfully inserted events plus a few
// counters, so the web UI can show a sample of the traffic going into
// Clickhouse without querying it. It is in-memory and per-process: a restart
// empties it, which is fine for a live "what is flowing right now" view.
type EventLog struct {
	mu      sync.Mutex
	ring    []Event // circular buffer, len <= eventLogCapacity
	next    int     // index the next event is written to once the ring is full
	total   uint64
	failed  uint64
	byType  map[string]uint64
	buckets [bucketCount]struct {
		sec int64
		n   uint64
	}
	now func() time.Time // overridable in tests
}

func NewEventLog() *EventLog {
	return &EventLog{byType: map[string]uint64{}, now: time.Now}
}

// Add records one successfully inserted event.
func (l *EventLog) Add(e Event) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.ring) < eventLogCapacity {
		l.ring = append(l.ring, e)
	} else {
		l.ring[l.next] = e
		l.next = (l.next + 1) % eventLogCapacity
	}
	l.total++
	l.byType[e.EventType]++
	sec := l.now().Unix()
	b := &l.buckets[sec%bucketCount]
	if b.sec != sec {
		b.sec, b.n = sec, 0
	}
	b.n++
}

// AddFailure counts an insert that returned an error.
func (l *EventLog) AddFailure() {
	l.mu.Lock()
	l.failed++
	l.mu.Unlock()
}

// Stats is the counters part of the /api/events/recent response.
type Stats struct {
	Total      uint64            `json:"total"`
	Failed     uint64            `json:"failed"`
	RatePerSec float64           `json:"ratePerSec"`
	ByType     map[string]uint64 `json:"byType"`
}

// Snapshot returns up to limit of the newest events (newest first) and the
// current stats.
func (l *EventLog) Snapshot(limit int) ([]Event, Stats) {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := len(l.ring)
	if limit <= 0 || limit > n {
		limit = n
	}
	out := make([]Event, 0, limit)
	for i := 1; i <= limit; i++ {
		// The newest element sits just before l.next (or at the end while
		// the ring is still filling, where l.next is 0).
		out = append(out, l.ring[((l.next-i)%n+n)%n])
	}
	byType := make(map[string]uint64, len(l.byType))
	for k, v := range l.byType {
		byType[k] = v
	}
	now := l.now().Unix()
	var recent uint64
	for _, b := range l.buckets {
		if b.sec > now-rateWindowSecs && b.sec <= now {
			recent += b.n
		}
	}
	return out, Stats{
		Total:      l.total,
		Failed:     l.failed,
		RatePerSec: float64(recent) / rateWindowSecs,
		ByType:     byType,
	}
}

// recordingInserter wraps another EventInserter and records every outcome in
// an EventLog, so the generator loop needs no knowledge of the UI.
type recordingInserter struct {
	inner EventInserter
	log   *EventLog
}

func (r recordingInserter) InsertEvent(ctx context.Context, e Event) error {
	if err := r.inner.InsertEvent(ctx, e); err != nil {
		r.log.AddFailure()
		return err
	}
	r.log.Add(e)
	return nil
}
