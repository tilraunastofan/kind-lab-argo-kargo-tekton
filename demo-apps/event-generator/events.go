package main

import (
	"math/rand"
	"time"
)

// Event mirrors one row of the Clickhouse `events` table defined in
// clickhouse.go's EnsureSchema. Keeping the Go struct field order/types in
// sync with the SQL column order matters for InsertEvent's positional `?`
// placeholders — if you add a column to the table, add the matching field
// here and update the INSERT statement together.
type Event struct {
	Timestamp time.Time // -> Clickhouse DateTime64(3), millisecond precision
	EventType string    // -> Clickhouse String, one of the values below
	Value     float64   // -> Clickhouse Float64, a stand-in metric (e.g. an order amount)
	UserID    uint32    // -> Clickhouse UInt32, a synthetic user identifier
}

// A small fixed vocabulary of event types, per the spec — real event
// pipelines usually have a much larger, evolving set, but a lab only needs
// enough variety to make dashboards/queries interesting.
var eventTypes = []string{"page_view", "click", "purchase", "error"}

// GenerateEvent produces one random synthetic event. It's a pure function
// (no side effects, same rng state in -> same result out) which is what
// makes it trivial to unit test below without a real Clickhouse instance.
func GenerateEvent(rng *rand.Rand) Event {
	return Event{
		Timestamp: time.Now(),
		EventType: eventTypes[rng.Intn(len(eventTypes))],
		Value:     rng.Float64() * 1000,
		UserID:    rng.Uint32(),
	}
}
