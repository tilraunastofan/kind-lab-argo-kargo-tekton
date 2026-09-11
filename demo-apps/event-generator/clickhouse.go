// demo-apps/event-generator/clickhouse.go
package main

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"

	// The blank import (`_`) runs this package's init() function for its
	// side effect only: registering a "clickhouse" driver with Go's
	// standard database/sql package via sql.Register(). We never call
	// anything in this package by name — sql.Open("clickhouse", ...) below
	// looks the driver up by that registered string. This is the same
	// pattern used by every database/sql driver in Go (lib/pq, go-sqlite3,
	// etc.) — database/sql defines the interface, the driver package wires
	// itself in.
	_ "github.com/ClickHouse/clickhouse-go/v2"
)

// EventInserter is the seam between "how do we get an Event into storage"
// and "everything else". Defining it as an interface (rather than passing
// *ClickhouseClient around directly) means handlers.go and main.go's
// runInserter don't need to know Clickhouse exists at all — and
// handlers_test.go (Task 4) can satisfy this interface with a trivial fake
// instead of standing up a real database for HTTP-layer tests. This is the
// same "depend on behavior, not concrete types" idea Kubernetes itself
// uses everywhere (a Service selects Pods by label, not by name; a
// PersistentVolumeClaim requests capabilities, not a specific disk).
type EventInserter interface {
	InsertEvent(ctx context.Context, e Event) error
}

// ClickhouseClient wraps a standard *sql.DB configured for Clickhouse.
// database/sql already pools connections internally, so there's no need
// for us to manage a connection pool ourselves.
type ClickhouseClient struct {
	db *sql.DB
}

// NewClickhouseClient opens a connection to addr (host:port — this is the
// Kubernetes Service DNS name + port the Deployment's CLICKHOUSE_ADDR env
// var will point at, e.g. "clickhouse.demo-app.svc.cluster.local:9000";
// Kubernetes' in-cluster DNS resolves that to whichever Pod(s) back the
// clickhouse Service), verifies it with a ping, ensures the events table
// exists, and returns a ready client. Doing the ping + schema check here
// (rather than lazily on first insert) means a broken connection fails
// fast at startup, which is what makes main.go's readiness state
// meaningful — see main.go's `ready.Store(true)` comment.
//
// user/password are optional (pass "" for both to connect unauthenticated
// — e.g. a local `docker run` against a bare ClickHouse container with no
// auth configured). In the cluster, the bitnami chart always auto-generates
// an admin password for its `default` user, so the Deployment (Task 7)
// wires CLICKHOUSE_PASSWORD from that chart's own Secret.
func NewClickhouseClient(ctx context.Context, addr, user, password string) (*ClickhouseClient, error) {
	dsn := fmt.Sprintf("clickhouse://%s/demo", addr)
	if user != "" {
		dsn = fmt.Sprintf("clickhouse://%s:%s@%s/demo", url.QueryEscape(user), url.QueryEscape(password), addr)
	}
	db, err := sql.Open("clickhouse", dsn)
	if err != nil {
		return nil, fmt.Errorf("opening clickhouse connection: %w", err)
	}
	// sql.Open doesn't actually dial anything — it just validates the DSN
	// and prepares a lazy connection pool. PingContext is what forces a
	// real round-trip, which is why we call it explicitly here.
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("pinging clickhouse: %w", err)
	}
	c := &ClickhouseClient{db: db}
	if err := c.EnsureSchema(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return c, nil
}

// EnsureSchema creates the events table if it doesn't already exist. Using
// `CREATE TABLE IF NOT EXISTS` as our entire "migration system" is a
// deliberate lab-scale shortcut (see the spec's "YAGNI for a lab this
// size") — a real production service would use a dedicated migration tool
// so schema changes are versioned and reviewable, not silently applied by
// every pod on every restart.
func (c *ClickhouseClient) EnsureSchema(ctx context.Context) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS events (
	timestamp DateTime64(3),
	event_type String,
	value Float64,
	user_id UInt32
) ENGINE = MergeTree()
ORDER BY timestamp
`
	// MergeTree is Clickhouse's primary table engine, built for large
	// append-heavy analytical workloads like this one — it's the engine
	// nearly every real Clickhouse table uses. ORDER BY timestamp sets its
	// primary sort key, which Clickhouse uses to build a sparse index and
	// physically sort data on disk — queries filtering or aggregating by
	// time range (the overwhelmingly common query pattern for event data)
	// benefit the most from this choice.
	_, err := c.db.ExecContext(ctx, ddl)
	if err != nil {
		return fmt.Errorf("ensuring events table: %w", err)
	}
	return nil
}

// InsertEvent writes one row. Using `?` placeholders (rather than string-
// formatting the values into the SQL) lets the driver send values
// separately from the query text — the standard defense against SQL
// injection, even though every value here is generator-produced rather
// than user input.
func (c *ClickhouseClient) InsertEvent(ctx context.Context, e Event) error {
	const stmt = `INSERT INTO events (timestamp, event_type, value, user_id) VALUES (?, ?, ?, ?)`
	_, err := c.db.ExecContext(ctx, stmt, e.Timestamp, e.EventType, e.Value, e.UserID)
	if err != nil {
		return fmt.Errorf("inserting event: %w", err)
	}
	return nil
}

// Close releases the underlying connection pool. main.go calls this via
// `defer client.Close()` so it runs on graceful shutdown — though note our
// simple ListenAndServe (Task 5) doesn't yet handle SIGTERM specially, so
// in practice Kubernetes will just SIGKILL the process after its default
// 30s termination grace period if it doesn't exit on its own; that's an
// acceptable simplification for a lab demo app.
func (c *ClickhouseClient) Close() error {
	return c.db.Close()
}
