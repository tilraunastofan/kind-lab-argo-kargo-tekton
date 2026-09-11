# Sub-Project 3a: Demo App (Event Generator) + Clickhouse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy a Go "event generator" service that writes synthetic
events into Clickhouse at a low background rate with a UI/API-triggered
high-load burst, running as an ArgoCD-managed app at
`https://event-generator.lab.test`, with its image built locally and pushed
to a private `ghcr.io` package — giving sub-project 3b (Kargo) a real,
versioned artifact to promote.

**Architecture:** A single Go binary (`demo-apps/event-generator`) holding a
pure, unit-tested rate/load-ramp controller and event generator, wired to a
thin Clickhouse client and an `net/http` server serving a static page + two
JSON/health endpoints. Deployed via two ArgoCD Applications (`clickhouse`
multi-source remote chart + local values, `event-generator` single-source
local chart) added to the existing `gitops/apps/` static App-of-Apps set,
exposed through the shared `helm/gateway` chart's per-app listener list —
the same pattern already used for Headlamp and the smoke test.

**Tech Stack:** Go 1.26 (`net/http`, no framework), `clickhouse-go/v2`
(stdlib `database/sql` driver), Docker multi-stage build, Helm charts,
ArgoCD `Application` CRs, plain bash scripts (`scripts/*.sh` conventions
already established in this repo).

**Spec:** `docs/superpowers/specs/2026-08-23-demo-app-design.md`

## Learning-Lab Commenting Standard

This repo's `CLAUDE.md` default is WHY-only comments (no restating what code
does). **This sub-project is an explicit, scoped exception**: the user has
asked for generous educational comments across every YAML manifest, script,
and Go file produced here, because this is a Kubernetes *learning* lab.
Every task below writes comments that explain the underlying concept (what a
Kubernetes `Service` selector does, why a Gateway API `HTTPRoute` needs a
`sectionName`, what ArgoCD's `sync-wave` ordering means, why Go's
`database/sql` needs a driver import for its side effect, etc.) — not just
the "why this specific line" comments used elsewhere in the repo. Apply this
standard to every file this plan creates, including ones where the code
blocks below don't spell out every comment verbatim — err on the side of
explaining a new concept the first time it appears in this codebase.

## Global Constraints

- Namespace for both Clickhouse and event-generator: `demo-app`.
- Registry: `ghcr.io/tilraunastofan/kind-lab/<image>:<git-short-sha>`, private packages. Local `docker login ghcr.io` (already configured on this machine) is assumed for pushes; the in-cluster pull uses a separate `read:packages`-scoped token via a `ghcr-pull` Secret.
- Clickhouse: `bitnami/clickhouse` chart, `https://charts.bitnami.com/bitnami`, version `9.4.4`, single replica, no keeper/cluster mode, small persistence, default database `demo`.
- `event-generator` creates its own `events` table with `CREATE TABLE IF NOT EXISTS` on startup — no separate migration mechanism.
- High-load duration is configurable via env var `HIGH_LOAD_DURATION_SECONDS` (default `30`); concurrent triggers extend/reset rather than stack.
- Background insert rate: one row every 200-1000ms (randomized) at baseline; 500-1000 events/sec during a high-load burst.
- `events` table columns: `timestamp` (DateTime64), `event_type` (String, one of `page_view`/`click`/`purchase`/`error`), `value` (Float64), `user_id` (UInt32).
- ArgoCD Application conventions to match exactly (see `gitops/apps/headlamp.yaml`/`smoke-test.yaml`): `syncPolicy.automated: {prune: true, selfHeal: true}`, `syncOptions: [CreateNamespace=true]`, `retry: {limit: 5, backoff: {duration: 10s, factor: 2, maxDuration: 2m}}`.
- Sync-waves: `clickhouse` gets `"-1"` (alongside `cert-manager`); `event-generator` gets `"1"` (alongside `headlamp`/`smoke-test`).
- repoURL for all Git-sourced Application entries: `git@github.com:tilraunastofan/kind-lab.git` (plain SSH port 22 — confirmed open and in current use by every existing Application; do not use the `ssh.github.com:443` workaround, that was reverted).
- GitHub repo slug for `gh`/registry purposes: `tilraunastofan/kind-lab`.

---

## File Structure

```
demo-apps/event-generator/
  go.mod, go.sum
  ratecontrol.go        # pure logic: baseline/high-load rate state machine
  ratecontrol_test.go
  events.go              # pure logic: random Event generation
  events_test.go
  clickhouse.go           # EventInserter interface + clickhouse-go impl (schema + insert)
  handlers.go             # HTTP handlers using EventInserter/RateController interfaces
  handlers_test.go
  main.go                 # wiring: connect, ensure schema, start background loop, start server
  static/index.html        # single-page UI
  Dockerfile               # multi-stage build

helm/clickhouse/
  values.yaml             # lab-scoped bitnami/clickhouse overrides

helm/event-generator/
  Chart.yaml
  values.yaml              # image.repository/image.tag, env vars
  templates/
    namespace.yaml (demo-app namespace, guarded so clickhouse's app doesn't double-create it — see Task 8)
    deployment.yaml
    service.yaml
  extras/
    certificate.yaml
    httproute.yaml

helm/gateway/values.yaml   # + one listeners entry for event-generator (modify)

gitops/apps/
  clickhouse.yaml           # new
  event-generator.yaml      # new

scripts/
  registry-secret-up.sh      # new
  build-and-push.sh          # new

README.md, CLAUDE.md         # modify: registry wording, sub-project 3a status
```

---

## Task 1: Go module scaffold + rate controller

**Files:**
- Create: `demo-apps/event-generator/go.mod`
- Create: `demo-apps/event-generator/ratecontrol.go`
- Test: `demo-apps/event-generator/ratecontrol_test.go`

**Interfaces:**
- Produces: `type RateController struct{...}`, `NewRateController(highLoadDuration time.Duration) *RateController`, `(*RateController) TriggerHighLoad()`, `(*RateController) IsHighLoad() bool`, `(*RateController) NextInterval(rng *rand.Rand) time.Duration` — baseline returns a random duration in `[200ms, 1000ms)`; high-load returns a random duration in `[1ms, 2ms)` (so the background loop's sleep-per-insert yields ~500-1000 events/sec — see Task 5). All methods safe for concurrent use (one caller triggers via HTTP, one caller reads via the background loop).

This is the core "temporary high-load burst" logic called out in the spec:
concurrent triggers extend/reset the duration rather than stacking multiple
ramps. Design it as a small state machine protected by a mutex, with a
monotonic "deadline" field so `TriggerHighLoad` just resets the deadline
forward instead of spawning timers.

- [ ] **Step 1: Initialize the Go module**

```bash
cd /Users/jakob/kind-lab/demo-apps/event-generator
go mod init github.com/tilraunastofan/kind-lab/demo-apps/event-generator
```

- [ ] **Step 2: Write the failing tests**

```go
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd demo-apps/event-generator && go test ./... -run RateController -v`
Expected: FAIL (build error — `RateController`/`NewRateController` undefined)

- [ ] **Step 4: Implement the rate controller**

```go
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd demo-apps/event-generator && go test ./... -run RateController -v`
Expected: PASS (all four tests)

- [ ] **Step 6: Commit**

```bash
git add demo-apps/event-generator/go.mod demo-apps/event-generator/ratecontrol.go demo-apps/event-generator/ratecontrol_test.go
git commit -m "feat(event-generator): add rate controller for baseline/high-load pacing"
```

---

## Task 2: Event generation

**Files:**
- Create: `demo-apps/event-generator/events.go`
- Test: `demo-apps/event-generator/events_test.go`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `type Event struct { Timestamp time.Time; EventType string; Value float64; UserID uint32 }`, `func GenerateEvent(rng *rand.Rand) Event`. Task 3 (Clickhouse client) and Task 4 (handlers, for the current-rate display) consume `Event`.

- [ ] **Step 1: Write the failing test**

```go
// demo-apps/event-generator/events_test.go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd demo-apps/event-generator && go test ./... -run GenerateEvent -v`
Expected: FAIL (build error — `Event`/`GenerateEvent` undefined)

- [ ] **Step 3: Implement event generation**

```go
// demo-apps/event-generator/events.go
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd demo-apps/event-generator && go test ./... -run GenerateEvent -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add demo-apps/event-generator/events.go demo-apps/event-generator/events_test.go
git commit -m "feat(event-generator): add synthetic event generation"
```

---

## Task 3: Clickhouse client

**Files:**
- Create: `demo-apps/event-generator/clickhouse.go`
- Modify: `demo-apps/event-generator/go.mod`, `go.sum` (adds `github.com/ClickHouse/clickhouse-go/v2`)

**Interfaces:**
- Consumes: `Event` (Task 2).
- Produces: `type EventInserter interface { InsertEvent(ctx context.Context, e Event) error }`, `type ClickhouseClient struct{...}` (implements `EventInserter`), `func NewClickhouseClient(ctx context.Context, addr string) (*ClickhouseClient, error)` (opens the connection, pings, and calls `EnsureSchema`), `func (c *ClickhouseClient) EnsureSchema(ctx context.Context) error`, `func (c *ClickhouseClient) Close() error`. Task 4 (handlers) and Task 5 (main) consume the `EventInserter` interface and `NewClickhouseClient`/`Close` respectively. Handlers' tests use a hand-written fake implementing `EventInserter` — no real Clickhouse needed for those tests.

No unit tests here: this file is a thin wrapper around the `clickhouse-go/v2`
driver (connection, `CREATE TABLE IF NOT EXISTS`, one `INSERT`) — the logic
worth testing (rate pacing, event shape, HTTP behavior) lives in Tasks 1, 2,
and 4 behind the `EventInserter` interface this task defines. This task is
verified by `go build` and later end-to-end in Task 14 against a real
Clickhouse.

- [ ] **Step 1: Add the clickhouse-go dependency**

```bash
cd demo-apps/event-generator
go get github.com/ClickHouse/clickhouse-go/v2@v2.30.0
```

- [ ] **Step 2: Implement the client**

```go
// demo-apps/event-generator/clickhouse.go
package main

import (
	"context"
	"database/sql"
	"fmt"

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
func NewClickhouseClient(ctx context.Context, addr string) (*ClickhouseClient, error) {
	db, err := sql.Open("clickhouse", fmt.Sprintf("clickhouse://%s/demo", addr))
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
```

- [ ] **Step 3: Verify it builds**

Run: `cd demo-apps/event-generator && go build ./...`
Expected: succeeds with no errors

- [ ] **Step 4: Commit**

```bash
git add demo-apps/event-generator/clickhouse.go demo-apps/event-generator/go.mod demo-apps/event-generator/go.sum
git commit -m "feat(event-generator): add clickhouse client with schema-on-startup"
```

---

## Task 4: HTTP handlers + static UI

**Files:**
- Create: `demo-apps/event-generator/handlers.go`
- Create: `demo-apps/event-generator/static/index.html`
- Test: `demo-apps/event-generator/handlers_test.go`

**Interfaces:**
- Consumes: `RateController` (Task 1: `IsHighLoad() bool`, `TriggerHighLoad()`), `EventInserter` (Task 3, only to type-check readiness — see `healthzHandler` below).
- Produces: `func newMux(rc *RateController, ready func() bool) *http.ServeMux` wiring `GET /`, `POST /api/load/high`, `GET /healthz`. Task 5 (main) consumes `newMux`.

- [ ] **Step 1: Write the failing tests**

```go
// demo-apps/event-generator/handlers_test.go
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealthzReturns200WhenReady(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true })
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestHealthzReturns503WhenNotReady(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return false })
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", rec.Code)
	}
}

func TestTriggerHighLoadEndpointStartsHighLoad(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true })
	req := httptest.NewRequest(http.MethodPost, "/api/load/high", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !rc.IsHighLoad() {
		t.Fatal("expected rate controller to be in high load after POST /api/load/high")
	}
}

func TestIndexServesHTML(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true })
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "" && ct != "text/html; charset=utf-8" {
		t.Fatalf("unexpected content type %q", ct)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd demo-apps/event-generator && go test ./... -run 'Healthz|TriggerHighLoad|Index' -v`
Expected: FAIL (build error — `newMux` undefined)

- [ ] **Step 3: Implement handlers and static UI**

```go
// demo-apps/event-generator/handlers.go
package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"net/http"
)

// //go:embed is a compiler directive (not a regular comment — the `//go:`
// prefix with no space is significant) that bakes the static/ directory's
// files into the compiled binary at build time. That means the Docker
// image's final stage (Task 6) doesn't need to COPY a separate static/
// folder — index.html ships inside the single binary, simplifying the
// distroless final image to just one file.
//
//go:embed static
var staticFS embed.FS

// newMux wires the HTTP routes onto a ServeMux (Go's built-in request
// router). `rc` is the RateController from ratecontrol.go; `ready` is a
// callback (rather than a plain bool) so /healthz always reports live,
// current state — see main.go, where it's backed by an atomic.Bool the
// background inserter also writes to.
func newMux(rc *RateController, ready func() bool) *http.ServeMux {
	mux := http.NewServeMux()

	// fs.Sub re-roots the embedded filesystem so paths are relative to
	// static/ instead of including that prefix — without it, http.FileServer
	// would serve this page at /static/index.html instead of /.
	staticContent, err := fs.Sub(staticFS, "static")
	if err != nil {
		panic(err) // embed misconfiguration, can only happen at build time
	}
	fileServer := http.FileServer(http.FS(staticContent))
	mux.Handle("/", fileServer)

	// POST /api/load/high — the spec's "Trigger High Load" endpoint. This
	// is a plain HTTP handler, not a Kubernetes concept, but it's worth
	// noting Kubernetes has no idea this endpoint or the load spike it
	// causes exist: from the platform's point of view this Pod just keeps
	// running and passing its liveness probe. Anything about *why* the
	// Pod's CPU/DB write rate jumped is purely application-level context —
	// this is exactly the kind of thing an observability tool (Datadog,
	// per this repo's later sub-project) is for.
	mux.HandleFunc("/api/load/high", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		rc.TriggerHighLoad()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"highLoad": true})
	})

	// GET /healthz backs both the Deployment's readinessProbe and
	// livenessProbe (see helm/event-generator/templates/deployment.yaml,
	// Task 7). Kubernetes hits this endpoint on a timer:
	//   - readinessProbe failing removes this Pod from the Service's
	//     load-balanced endpoints (traffic stops routing here) without
	//     restarting it — useful while Clickhouse is still coming up.
	//   - livenessProbe failing gets the Pod restarted entirely — useful
	//     if the process is stuck/deadlocked, not just temporarily
	//     degraded.
	// Returning 503 here (rather than just always 200) is what lets those
	// two probes actually do their job instead of being a rubber stamp.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if !ready() {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})

	return mux
}
```

```html
<!-- demo-apps/event-generator/static/index.html -->
<!--
  Deliberately no frontend framework/build step, per the spec — this file
  is embedded directly into the Go binary via handlers.go's //go:embed and
  served as-is. A more complex Kubernetes app might build this as a
  separate frontend container behind its own Service, but for a single
  lab demo page, one static file served by the same process that owns the
  API it calls is the simplest thing that works.
-->
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>event-generator</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; }
    button { font-size: 1rem; padding: 0.5rem 1rem; cursor: pointer; }
    #status { margin-top: 1rem; color: #555; }
  </style>
</head>
<body>
  <h1>event-generator</h1>
  <p>Writes synthetic events into Clickhouse continuously at a low background rate.</p>
  <button id="trigger">Trigger High Load</button>
  <p id="status"></p>
  <script>
    // Calls the same-origin POST /api/load/high handler defined in
    // handlers.go. Same-origin means no CORS configuration is needed —
    // this page and the API it calls are served by the same Go process,
    // behind the same https://event-generator.lab.test Gateway listener.
    document.getElementById('trigger').addEventListener('click', async () => {
      const status = document.getElementById('status');
      status.textContent = 'Triggering...';
      try {
        const res = await fetch('/api/load/high', { method: 'POST' });
        if (!res.ok) throw new Error('request failed: ' + res.status);
        status.textContent = 'High load triggered.';
      } catch (err) {
        status.textContent = 'Error: ' + err.message;
      }
    });
  </script>
</body>
</html>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd demo-apps/event-generator && go test ./... -v`
Expected: PASS (all tests across Tasks 1, 2, and 4)

- [ ] **Step 5: Commit**

```bash
git add demo-apps/event-generator/handlers.go demo-apps/event-generator/handlers_test.go demo-apps/event-generator/static/index.html
git commit -m "feat(event-generator): add HTTP handlers and static UI"
```

---

## Task 5: main.go wiring (background inserter + server startup)

**Files:**
- Create: `demo-apps/event-generator/main.go`

**Interfaces:**
- Consumes: `NewRateController` (Task 1), `GenerateEvent` (Task 2), `NewClickhouseClient`/`EventInserter`/`Close` (Task 3), `newMux` (Task 4).
- Produces: `func main()` — the deployable entrypoint. Nothing downstream in this repo consumes `main` directly; Task 6 (Dockerfile) builds this package.

Reads three env vars: `CLICKHOUSE_ADDR` (required, `host:port`),
`HIGH_LOAD_DURATION_SECONDS` (optional, default `30`), `PORT` (optional,
default `8080`). No unit test — this is wiring/`main`, exercised by build
and later by the real deployment in Task 14. Note the readiness flag: the
background loop and the `/healthz` handler both read/write a single
`atomic.Bool` so `ready()` reflects "clickhouse connection currently
established", matching the spec's readiness/liveness probe requirement.

- [ ] **Step 1: Implement main.go**

```go
// demo-apps/event-generator/main.go
package main

import (
	"context"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

// main is the process entrypoint — this is what the Dockerfile's ENTRYPOINT
// (Task 6) runs. Configuration comes entirely from environment variables
// rather than command-line flags or a config file, which is the standard
// way to configure a container in Kubernetes: the Deployment's `env:` list
// (helm/event-generator/templates/deployment.yaml, Task 7) is how the
// cluster hands this process its settings, no ConfigMap volume mount or
// flags needed for something this small.
func main() {
	// CLICKHOUSE_ADDR has no default and fails fast if missing — this app
	// should never silently run without a database to write to. Compare
	// this to Kubernetes' own philosophy of failing a Pod's readiness
	// probe rather than serving degraded traffic silently.
	addr := os.Getenv("CLICKHOUSE_ADDR")
	if addr == "" {
		log.Fatal("CLICKHOUSE_ADDR is required")
	}

	highLoadSeconds := 30
	if v := os.Getenv("HIGH_LOAD_DURATION_SECONDS"); v != "" {
		parsed, err := strconv.Atoi(v)
		if err != nil {
			log.Fatalf("invalid HIGH_LOAD_DURATION_SECONDS %q: %v", v, err)
		}
		highLoadSeconds = parsed
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// context.Background() is Go's "root" context — one with no deadline
	// or cancellation, appropriate here since this process is meant to run
	// forever until Kubernetes kills it. It's threaded through every
	// database call below so operations can eventually be cancelled if we
	// ever wire up graceful shutdown.
	ctx := context.Background()
	client, err := NewClickhouseClient(ctx, addr)
	if err != nil {
		log.Fatalf("connecting to clickhouse: %v", err)
	}
	defer client.Close()

	// atomic.Bool lets both the background goroutine (writer) and the
	// /healthz HTTP handler (reader, on yet another goroutine per request)
	// touch this flag without a data race, without needing a full
	// sync.Mutex for something this simple — a lighter-weight tool than
	// the mutex used in ratecontrol.go, appropriate because this is just
	// one bool, not a multi-field state transition.
	var ready atomic.Bool
	ready.Store(true) // NewClickhouseClient already pinged + ensured schema above

	rc := NewRateController(time.Duration(highLoadSeconds) * time.Second)

	// `go` launches runInserter as a separate goroutine — Go's lightweight
	// concurrency primitive (not an OS thread) — so it runs concurrently
	// with http.ListenAndServe below rather than blocking main() from ever
	// reaching the HTTP server. This single process therefore has (at
	// least) two things happening at once: writing to Clickhouse in the
	// background, and serving HTTP requests in the foreground — all inside
	// one Kubernetes Pod with one container.
	go runInserter(ctx, client, rc, ready.Store)

	mux := newMux(rc, ready.Load)
	log.Printf("event-generator listening on :%s", port)
	// ListenAndServe blocks forever (until an error) — this is what keeps
	// the container's process alive, which is what keeps the Pod "Running"
	// from Kubernetes' point of view. If this returns, the process exits,
	// and Kubernetes restarts the container per its restartPolicy.
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("http server: %v", err)
	}
}

// runInserter loops forever, inserting one event and sleeping for
// rc.NextInterval() each iteration. On an insert error it marks the service
// not-ready (via setReady) and backs off briefly rather than crashing —
// crashing on every transient DB blip would cause Kubernetes to
// restart the whole Pod (and re-run readiness probes from scratch) far more
// aggressively than needed. Instead we lean on the /healthz-driven
// readiness/liveness probes: if Clickhouse is unreachable for long enough
// that the liveness probe itself starts failing, *then* Kubernetes restarts
// the Pod — that's the intended failure path, not this loop panicking.
func runInserter(ctx context.Context, inserter EventInserter, rc *RateController, setReady func(bool)) {
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	for {
		e := GenerateEvent(rng)
		if err := inserter.InsertEvent(ctx, e); err != nil {
			log.Printf("insert failed: %v", err)
			setReady(false)
			time.Sleep(time.Second)
			setReady(true)
			continue
		}
		time.Sleep(rc.NextInterval(rng))
	}
}
```

- [ ] **Step 2: Verify it builds and existing tests still pass**

Run: `cd demo-apps/event-generator && go build ./... && go vet ./... && go test ./...`
Expected: build succeeds, vet is clean, all tests PASS

- [ ] **Step 3: Commit**

```bash
git add demo-apps/event-generator/main.go
git commit -m "feat(event-generator): wire background inserter and HTTP server in main"
```

---

## Task 6: Dockerfile

**Files:**
- Create: `demo-apps/event-generator/Dockerfile`

**Interfaces:**
- Consumes: the `demo-apps/event-generator` Go module (Tasks 1-5).
- Produces: a built image taggable as `ghcr.io/tilraunastofan/kind-lab/event-generator:<tag>`. Task 12 (`build-and-push.sh`) and Task 7 (Helm `values.yaml` `image.repository`) reference this image name.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# demo-apps/event-generator/Dockerfile
#
# Multi-stage build: the "build" stage has the full Go toolchain (hundreds
# of MB) but nothing from it ends up in the final image except the compiled
# binary, copied across via `COPY --from=build`. This keeps the shipped
# image small and free of build tooling/source code that has no business
# being in a running container.

FROM golang:1.26 AS build
WORKDIR /src

# Copying go.mod/go.sum and running `go mod download` before copying the
# rest of the source lets Docker cache this (usually slow) layer — it only
# re-runs when dependencies change, not on every source-code edit, thanks
# to Docker's layer caching working off each COPY's content hash.
COPY go.mod go.sum ./
RUN go mod download
COPY . .

# CGO_ENABLED=0 produces a statically-linked binary with no dependency on
# the host's C library (glibc/musl) — required here because the final stage
# below is `distroless/static`, an image so minimal it has no C library at
# all. GOOS=linux is explicit in case this is ever built on a non-Linux
# machine (e.g. this repo's Docker Desktop/OrbStack setup on macOS) — the
# image that runs inside the kind cluster must always be a Linux binary
# regardless of what built it.
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/event-generator .

# distroless images (https://github.com/GoogleContainerTools/distroless)
# contain just the app and its runtime dependencies — no shell, no package
# manager, no coreutils. That shrinks both the image size and the attack
# surface (there's no `/bin/sh` for an attacker who gets code execution to
# pivot into), at the cost of `kubectl exec ... sh` not working against
# this container — a deliberate, common production trade-off.
FROM gcr.io/distroless/static-debian12
COPY --from=build /out/event-generator /event-generator

# EXPOSE is documentation, not enforcement — it doesn't actually open the
# port. The real exposure happens via the Kubernetes Service (Task 7's
# service.yaml) targeting this same containerPort: 8080.
EXPOSE 8080
ENTRYPOINT ["/event-generator"]
```

- [ ] **Step 2: Verify the image builds**

Run: `cd demo-apps/event-generator && docker build -t event-generator:local-test .`
Expected: build succeeds (all stages complete, final image produced)

- [ ] **Step 3: Sanity-check the binary starts (fails fast without Clickhouse, which is expected)**

Run: `docker run --rm event-generator:local-test`
Expected: prints `CLICKHOUSE_ADDR is required` and exits non-zero — confirms the entrypoint runs and env-var validation works. Then clean up: `docker rmi event-generator:local-test`

- [ ] **Step 4: Commit**

```bash
git add demo-apps/event-generator/Dockerfile
git commit -m "feat(event-generator): add multi-stage Dockerfile"
```

---

## Task 7: Helm chart for event-generator

**Files:**
- Create: `helm/event-generator/Chart.yaml`
- Create: `helm/event-generator/values.yaml`
- Create: `helm/event-generator/templates/deployment.yaml`
- Create: `helm/event-generator/templates/service.yaml`
- Create: `helm/event-generator/extras/certificate.yaml`
- Create: `helm/event-generator/extras/httproute.yaml`

**Interfaces:**
- Consumes: image name from Task 6 (`ghcr.io/tilraunastofan/kind-lab/event-generator`), Gateway listener name from Task 9 (`https-event-generator`), the `ghcr-pull` Secret name from Task 11.
- Produces: a `helm template` renderable chart. Task 10 (`gitops/apps/event-generator.yaml`) points its Application `source.path` at this directory.

Namespace `demo-app` is created by this chart (`CreateNamespace=true` in the
Application's `syncOptions` — matching the existing `headlamp`/`smoke-test`
pattern — makes an explicit `Namespace` manifest unnecessary; the
`clickhouse` Application in Task 8 also targets `demo-app` and gets the same
`CreateNamespace=true` treatment, so whichever Application syncs first
creates it, and the second is a no-op).

- [ ] **Step 1: Chart.yaml**

```yaml
# helm/event-generator/Chart.yaml
#
# The minimum a Helm chart needs to exist: apiVersion (v2 = the Helm 3
# chart format), a name, and a chart version (bumped when the chart's
# templates/structure change — unrelated to the app's own image tag below,
# which is an *application* version tracked separately in values.yaml).
# Helm itself is just a templating engine over plain Kubernetes YAML — every
# file under templates/ gets rendered with values.yaml's values substituted
# in, then the result is what ArgoCD actually applies to the cluster.
apiVersion: v2
name: event-generator
description: Go event-generator demo app writing synthetic events into Clickhouse
version: 0.1.0
```

- [ ] **Step 2: values.yaml**

```yaml
# helm/event-generator/values.yaml
#
# The knobs templates/*.yaml reference via {{ .Values.<key> }}. This is the
# file a human (today) or Kargo (sub-project 3b) edits to roll out a new
# image — nothing else in this chart needs to change to deploy a new build.
image:
  repository: ghcr.io/tilraunastofan/kind-lab/event-generator
  tag: "" # set by a human today, by Kargo in sub-project 3b

# The Kubernetes Service DNS name for Clickhouse, in the cluster-internal
# form <service-name>.<namespace>.svc.cluster.local:<port>. CoreDNS (the
# cluster's built-in DNS server) resolves this automatically for any
# Service in any namespace — no manual /etc/hosts-style wiring needed,
# unlike the *.lab.test hostnames this repo resolves externally via the
# macOS resolver + in-cluster dnsmasq. Port 9000 is Clickhouse's native TCP
# protocol port (as opposed to 8123, its HTTP interface) — this must match
# whatever port name/number the bitnami/clickhouse chart's Service exposes;
# double-check against the chart's actual output in Task 8 Step 2.
clickhouseAddr: clickhouse.demo-app.svc.cluster.local:9000

highLoadDurationSeconds: 30
```

- [ ] **Step 3: deployment.yaml**

```yaml
# helm/event-generator/templates/deployment.yaml
#
# A Deployment is Kubernetes' standard way to run a stateless, replicated
# app: it manages a ReplicaSet (which in turn manages the actual Pods),
# handling rolling updates, self-healing (a crashed Pod is replaced
# automatically), and scaling. `event-generator` has no per-Pod identity or
# storage of its own — all its state lives in Clickhouse — so a Deployment
# is the right primitive (as opposed to a StatefulSet, which the bitnami/
# clickhouse chart itself likely uses under the hood for Clickhouse, since
# that does need stable identity/storage per replica).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: event-generator
  namespace: demo-app
spec:
  # A lab demo app doesn't need multiple replicas — one Pod is enough to
  # prove the mechanism. (Multiple replicas would also each run their own
  # independent background inserter loop, multiplying the insert rate in a
  # way the spec doesn't ask for.)
  replicas: 1
  # selector tells the Deployment which Pods belong to it, by label match —
  # this must equal template.metadata.labels below. This label-selector
  # pattern (not "Pods with this exact name") is how nearly everything in
  # Kubernetes groups objects: Services, Deployments, NetworkPolicies all
  # select Pods this same way.
  selector:
    matchLabels:
      app: event-generator
  # template is the Pod template — the spec every Pod this Deployment
  # creates is stamped from. Changing anything under `template` (a new
  # image tag, a new env var) triggers a rolling update: new Pods matching
  # the new template come up, old ones are terminated, one at a time by
  # default.
  template:
    metadata:
      labels:
        app: event-generator
    spec:
      # Without this, the kubelet would try to pull
      # ghcr.io/tilraunastofan/kind-lab/event-generator anonymously and
      # fail with ImagePullBackOff, since the package is private. This
      # references the Secret scripts/registry-secret-up.sh (Task 11)
      # creates in this same demo-app namespace — imagePullSecrets only
      # works with Secrets in the same namespace as the Pod.
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: event-generator
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 8080
          # env vars are how this chart hands the container its runtime
          # config — matching exactly what main.go reads via os.Getenv.
          # {{ ... | quote }} wraps the templated value in YAML double
          # quotes, which matters for highLoadDurationSeconds: without it,
          # Helm would render a bare YAML integer (30) where a Kubernetes
          # env var value must be a string.
          env:
            - name: CLICKHOUSE_ADDR
              value: {{ .Values.clickhouseAddr | quote }}
            - name: HIGH_LOAD_DURATION_SECONDS
              value: {{ .Values.highLoadDurationSeconds | quote }}
          # readinessProbe: an HTTP GET to /healthz on a timer. Failing
          # this doesn't restart the Pod — it just removes it from the
          # Service's endpoint list, so no traffic gets routed here until
          # it passes again. initialDelaySeconds gives the container a
          # moment to start before the first check.
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
          # livenessProbe: same endpoint, but failing this restarts the
          # container entirely — reserved for "this process is broken and
          # needs a fresh start", which is why its thresholds here are a
          # touch more relaxed (longer initialDelaySeconds/periodSeconds)
          # than the readinessProbe's.
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
```

- [ ] **Step 4: service.yaml**

```yaml
# helm/event-generator/templates/service.yaml
#
# A Service is a stable network identity for a set of Pods — the Deployment
# above can churn Pods (restarts, rolling updates, each getting a new IP),
# but `event-generator.demo-app.svc.cluster.local` always resolves to
# whichever Pods currently match `selector` below and are passing their
# readinessProbe. This is what the HTTPRoute (extras/httproute.yaml) routes
# to, and what any other in-cluster workload would use to reach this app.
apiVersion: v1
kind: Service
metadata:
  name: event-generator
  namespace: demo-app
spec:
  # No `type:` field means this defaults to ClusterIP — only reachable from
  # inside the cluster. External access comes entirely through the shared
  # Gateway (Cilium's Gateway API implementation) via the HTTPRoute below,
  # not by exposing this Service directly — the same pattern every other
  # app in this repo (Headlamp, ArgoCD, the smoke test) uses.
  selector:
    app: event-generator
  ports:
    # port is what other things inside the cluster connect to (80, the
    # HTTPRoute's backendRef below uses this); targetPort is the actual
    # port the container listens on (8080, matching main.go's default and
    # the Deployment's containerPort). They don't have to match, and
    # deliberately don't here — 80 is the conventional "just HTTP" port for
    # cluster-internal Service traffic, kept separate from whatever port
    # the app binary itself happens to use.
    - port: 80
      targetPort: 8080
```

- [ ] **Step 5: extras/certificate.yaml and extras/httproute.yaml (same pattern as `helm/headlamp/extras`)**

```yaml
# helm/event-generator/extras/certificate.yaml
#
# cert-manager's Certificate CRD is a *request* for a TLS cert, not the cert
# itself — cert-manager's controller watches for Certificate objects, talks
# to the issuer named in issuerRef (here, the cluster's step-ca ACME
# ClusterIssuer, issuing certs trusted by this Mac's system keychain — see
# CLAUDE.md's TLS section) to actually obtain one, then writes the result
# into a Kubernetes Secret named `secretName`. This Certificate lives in the
# lab-gateway namespace (not demo-app) because that's where the Gateway
# resource that will reference the resulting Secret lives — a Gateway's
# listener certificateRef must be a Secret in the Gateway's own namespace.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: event-generator-tls
  namespace: lab-gateway
spec:
  secretName: event-generator-tls
  dnsNames:
    - event-generator.lab.test
  issuerRef:
    name: step-ca-acme
    kind: ClusterIssuer
```

```yaml
# helm/event-generator/extras/httproute.yaml
#
# HTTPRoute is part of the Gateway API (the modern successor to Ingress) —
# it attaches routing rules to a Gateway via parentRefs, without needing to
# touch the Gateway object itself. That's what lets every app in this repo
# add its own HTTPRoute independently while helm/gateway's chart remains the
# single owner of the shared lab-gateway Gateway's listener list.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: event-generator
  namespace: demo-app
spec:
  parentRefs:
    - name: lab-gateway
      namespace: lab-gateway
      # sectionName pins this route to one specific listener on the
      # Gateway (the https-event-generator listener helm/gateway/values.yaml
      # renders in Task 9) rather than matching every listener on
      # lab-gateway — required here since the Gateway has many listeners,
      # one per app, and this route should only ever serve HTTPS traffic
      # for event-generator.lab.test.
      sectionName: https-event-generator
  hostnames:
    - event-generator.lab.test
  rules:
    - backendRefs:
        # Routes to the Service defined in templates/service.yaml, port 80
        # — the Service's ClusterIP port, which then forwards to the Pod's
        # containerPort 8080 per that Service's targetPort.
        - name: event-generator
          port: 80
```

- [ ] **Step 6: Verify the chart renders**

Run: `helm template helm/event-generator --set image.tag=test`
Expected: valid YAML output for Deployment and Service, no template errors (extras/ is applied separately as a raw directory via the Application's second source — see Task 10 — so `helm template` alone won't render it; that's expected and matches the headlamp precedent)

- [ ] **Step 7: Commit**

```bash
git add helm/event-generator
git commit -m "feat(event-generator): add Helm chart, Certificate, and HTTPRoute"
```

---

## Task 8: Clickhouse Helm values

**Files:**
- Create: `helm/clickhouse/values.yaml`

**Interfaces:**
- Produces: the `$values`-referenced file for the `clickhouse` multi-source Application in Task 10.

- [ ] **Step 1: Write lab-scoped values**

```yaml
# helm/clickhouse/values.yaml
#
# Lab-scoped overrides for the third-party bitnami/clickhouse chart —
# committed here and referenced by gitops/apps/clickhouse.yaml's `$values`
# source (Task 10), the same "remote chart + our own values file" pattern
# already used for cert-manager/ArgoCD/Headlamp in this repo. We don't fork
# or vendor the chart itself, just override the handful of settings that
# matter for a lab: single instance, no keeper/cluster mode, small
# persistence. Not committed with any credentials — bitnami's chart
# auto-generates an admin password into a Kubernetes Secret if one isn't
# set here, which is exactly what we want (no plaintext DB password in Git).

# A production Clickhouse cluster shards data across multiple nodes for
# horizontal scale; `shards: 1` and `replicaCount: 1` together mean "just
# run one single-node instance" — plenty for a lab's write volume, and far
# simpler to reason about and debug.
shards: 1
replicaCount: 1

# ClickHouse Keeper (a ZooKeeper-compatible coordination service) is only
# needed for multi-node replication/coordination. With a single instance
# there's nothing to coordinate, so it's disabled outright — running it
# anyway would just be extra Pods doing nothing useful.
keeper:
  enabled: false

auth:
  username: default
  database: demo # the `demo` database this app's `events` table (created by clickhouse.go's EnsureSchema) lives in

persistence:
  enabled: true
  # Backed by a PersistentVolumeClaim — without this, Clickhouse's data
  # would live only in the container's writable layer and vanish the
  # instant the Pod is rescheduled or restarted. 4Gi is generous for a lab
  # demo's data volume.
  size: 4Gi

resources:
  # requests: what Kubernetes reserves for scheduling — the scheduler will
  # only place this Pod on a node that has at least this much unclaimed
  # capacity.
  requests:
    cpu: 100m # 100 millicores = 0.1 of one CPU core
    memory: 256Mi
  # limits: the hard ceiling — memory: exceeding this gets the container
  # OOMKilled by the kernel; CPU has no limit set here, so it can burst
  # above its request if the node has spare capacity (CPU limits, unlike
  # memory limits, only throttle rather than kill, which is why omitting
  # one is a common lab-scale simplification).
  limits:
    memory: 512Mi
```

- [ ] **Step 2: Verify values are structurally valid against the chart**

Run: `helm show values oci://registry-1.docker.io/bitnamicharts/clickhouse --version 9.4.4 > /tmp/ch-defaults.yaml 2>&1 || helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update bitnami && helm template test bitnami/clickhouse --version 9.4.4 -f helm/clickhouse/values.yaml > /tmp/ch-rendered.yaml`
Expected: `helm template` succeeds and produces manifests (StatefulSet, Service, Secret) with no "unknown field"-type errors. If the `oci://` pull works, cross-check the key names in `/tmp/ch-defaults.yaml` (`shards`/`keeper.enabled`/`auth.username`/`auth.database`/`persistence.size` may differ slightly by chart version — adjust `helm/clickhouse/values.yaml` to match whatever key names the actual 9.4.4 chart uses before proceeding).

- [ ] **Step 3: Commit**

```bash
git add helm/clickhouse/values.yaml
git commit -m "feat(clickhouse): add lab-scoped values for bitnami/clickhouse chart"
```

---

## Task 9: Gateway listener for event-generator

**Files:**
- Modify: `helm/gateway/values.yaml`

**Interfaces:**
- Consumes: nothing new — follows the existing `listeners` list shape (`name`, `hostname`, `certificateRef`) already rendered by `helm/gateway/templates/gateway.yaml`.
- Produces: a Gateway listener pair `http-event-generator`/`https-event-generator` on `event-generator.lab.test`, which Task 7's `extras/httproute.yaml` (`sectionName: https-event-generator`) and Task 7's `extras/certificate.yaml` (`secretName: event-generator-tls` matching `certificateRef`) both depend on.

- [ ] **Step 1: Add the listener entry**

```yaml
# helm/gateway/values.yaml (full file after edit)
#
# This whole list feeds helm/gateway/templates/gateway.yaml's `{{ range
# .Values.listeners }}` loop, which renders one HTTP+HTTPS listener pair
# per entry onto the single shared lab-gateway Gateway object. A `kubectl
# apply` on a Gateway replaces its entire spec.listeners array wholesale —
# there's no way to additively patch just one listener in — so this file is
# the single source of truth for every hostname the cluster serves, and
# onboarding event-generator here is a one-line append, not a
# listener-ownership conflict with any other app's chart.
listeners:
  - name: smoke
    hostname: smoke.lab.test
    certificateRef: smoke-tls
  - name: argocd
    hostname: argocd.lab.test
    certificateRef: argocd-tls
  - name: headlamp
    hostname: headlamp.lab.test
    certificateRef: headlamp-tls
  # certificateRef here must match the Certificate's spec.secretName in
  # helm/event-generator/extras/certificate.yaml (Task 7) — cert-manager
  # writes the issued cert into a Secret by that name, and this Gateway
  # listener's TLS termination reads it back out by the same name.
  - name: event-generator
    hostname: event-generator.lab.test
    certificateRef: event-generator-tls
```

- [ ] **Step 2: Verify the chart renders with the new listener**

Run: `helm template helm/gateway | grep -A6 'name: https-event-generator'`
Expected: shows the new HTTPS listener block with `hostname: event-generator.lab.test` and `certificateRefs: [{name: event-generator-tls}]`, paired with an `http-event-generator` HTTP listener on the same hostname (per the Cilium workaround comment already in the template)

- [ ] **Step 3: Commit**

```bash
git add helm/gateway/values.yaml
git commit -m "feat(gateway): add event-generator listener"
```

---

## Task 10: gitops Applications for clickhouse and event-generator

**Files:**
- Create: `gitops/apps/clickhouse.yaml`
- Create: `gitops/apps/event-generator.yaml`

**Interfaces:**
- Consumes: `helm/clickhouse/values.yaml` (Task 8), `helm/event-generator` chart + `extras/` (Task 7).
- Produces: two `Application` CRs picked up by `root-app` (`gitops/root-app.yaml`, already watching `gitops/apps/` — no changes needed there).

- [ ] **Step 1: clickhouse.yaml — multi-source, matching the headlamp pattern, sync-wave -1**

```yaml
# gitops/apps/clickhouse.yaml
#
# An ArgoCD Application is a CRD instance that tells ArgoCD "watch this
# source, keep the cluster's live state matching it". root-app.yaml (the
# App-of-Apps) watches the whole gitops/apps/ directory, so simply adding
# this file here is enough for ArgoCD to discover and start managing it —
# no separate registration step.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: clickhouse
  namespace: argocd
  annotations:
    # sync-wave controls ordering: ArgoCD syncs lower-numbered waves first
    # and waits for them to be Healthy before moving to the next wave.
    # "-1" here (matching cert-manager's own wave) means Clickhouse comes
    # up before the default wave "0"/"1" apps — notably before
    # event-generator (wave "1" below), whose Pod would otherwise
    # crash-loop trying to reach a Clickhouse Service that doesn't exist
    # yet. This is soft ordering, not a hard dependency block — ArgoCD
    # doesn't understand "this app needs that Service to exist", only wave
    # numbers.
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  # Multiple `sources:` (a "multi-source Application") lets one Application
  # combine a remote Helm chart with a values file from a *different* repo
  # — here, the public bitnami chart repo plus this repo's own
  # helm/clickhouse/values.yaml. The second source has no `chart:`/`path:`,
  # just a `ref: values` name that the first source's `helm.valueFiles`
  # references via the `$values/` prefix — ArgoCD resolves that at sync
  # time to "the file at this path, in the source named `values`".
  sources:
    - repoURL: https://charts.bitnami.com/bitnami
      chart: clickhouse
      targetRevision: 9.4.4 # the chart version, not the app's own ClickHouse version — Helm chart versions and the software they package are versioned independently
      helm:
        valueFiles:
          - $values/helm/clickhouse/values.yaml
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc # "this same cluster" — ArgoCD can also manage remote clusters, unused here
    namespace: demo-app
  syncPolicy:
    automated:
      prune: true   # delete cluster objects that are no longer in the Git source (keeps the cluster from drifting to include stuff nobody declared anymore)
      selfHeal: true # revert any manual/out-of-band change back to match Git — this is what makes ArgoCD GitOps rather than just "kubectl apply on a timer"
    syncOptions:
      - CreateNamespace=true # ArgoCD creates the demo-app namespace itself if it doesn't already exist, instead of requiring a separate Namespace manifest
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 2m
```

- [ ] **Step 2: event-generator.yaml — single-source, matching the smoke-test pattern, sync-wave 1, with the extras directory as a second source (matching headlamp's third source)**

```yaml
# gitops/apps/event-generator.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: event-generator
  namespace: argocd
  annotations:
    # Wave "1" (after clickhouse's wave "-1" and cert-manager's wave "-1")
    # — matches headlamp and smoke-test's own wave "1", since none of these
    # apps have ordering dependencies on each other, only on the
    # lower-wave infra apps.
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  # Two sources, both pointing at *this same repo* — this is a different
  # multi-source shape than clickhouse.yaml's remote-chart-plus-values
  # pattern above. Here, the first source is our own local Helm chart
  # (helm/event-generator, with its Chart.yaml/templates/values.yaml); the
  # second is a plain "directory" source with no Helm involved at all — it
  # just applies every *.yaml file under helm/event-generator/extras/
  # (the Certificate and HTTPRoute) as raw Kubernetes manifests. Splitting
  # them this way lets the Certificate live in the lab-gateway namespace
  # while the Helm-templated Deployment/Service live in demo-app — a Helm
  # release can only target one destination namespace, but a second
  # "directory" source has no such restriction since it isn't a Helm
  # release at all.
  sources:
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      path: helm/event-generator
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      path: helm/event-generator/extras
      directory:
        include: "*.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 2m
```

- [ ] **Step 3: Validate both manifests parse as valid Kubernetes YAML**

Run: `kubectl apply --dry-run=client -f gitops/apps/clickhouse.yaml -f gitops/apps/event-generator.yaml`
Expected: `application.argoproj.io/clickhouse created (dry run)` and `application.argoproj.io/event-generator created (dry run)` — confirms the CRs are well-formed (ArgoCD's CRD must already be installed in-cluster for this to validate against the schema; if the cluster isn't up yet, `--dry-run=client` still validates generic YAML/structure without a live apiserver check — either is acceptable here)

- [ ] **Step 4: Commit**

```bash
git add gitops/apps/clickhouse.yaml gitops/apps/event-generator.yaml
git commit -m "feat: add ArgoCD Applications for clickhouse and event-generator"
```

---

## Task 11: registry-secret-up.sh

**Files:**
- Create: `scripts/registry-secret-up.sh`

**Interfaces:**
- Consumes: `scripts/lib.sh` (`log`/`die`/`require_cmd`), a `GHCR_PULL_TOKEN` env var the user sets locally (not committed).
- Produces: the `ghcr-pull` Secret in the `demo-app` namespace that Task 7's `deployment.yaml` references via `imagePullSecrets`.

Mirrors the idempotent-secret-application style already used in
`scripts/argocd-up.sh`'s `apply_repo_creds` (a `kubectl apply -f -`
heredoc, safe to re-run).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the ghcr-pull imagePullSecret in the demo-app namespace,
# used by helm/event-generator's Deployment to pull private ghcr.io images.
# Requires a read:packages-scoped GitHub token in GHCR_PULL_TOKEN (not
# committed to Git — export it in your shell before running this).
#
# Why this exists at all: Kubernetes doesn't know how to authenticate to a
# private registry on its own. A Secret of type kubernetes.io/dockerconfigjson
# (which `kubectl create secret docker-registry` builds for us) holds
# registry credentials in the same format as a local ~/.docker/config.json;
# a Pod referencing it via imagePullSecrets lets the kubelet use those
# credentials when pulling the image. This script is deliberately separate
# from build-and-push.sh (Task 12) — pushing needs *write* access, pulling
# only needs *read* access, so they use differently-scoped tokens on
# purpose (least privilege: the credential baked into the cluster can only
# read images, never publish or delete them).

main() {
  require_cmd kubectl

  if [ -z "${GHCR_PULL_TOKEN:-}" ]; then
    die "GHCR_PULL_TOKEN is not set — export a read:packages-scoped GitHub token first"
  fi

  # `create ... --dry-run=client -o yaml | kubectl apply -f -` is a common
  # idempotency trick: `kubectl create` alone would fail on a second run
  # ("already exists"), but rendering it client-side (--dry-run=client,
  # meaning "just print the YAML this *would* create, don't actually talk
  # to the apiserver") and piping into `apply` makes the whole thing safe
  # to re-run — apply creates on the first run and updates in place on
  # every run after. Same pattern used for the namespace below.
  log "ensuring demo-app namespace exists"
  kubectl create namespace demo-app --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing ghcr-pull imagePullSecret in demo-app"
  kubectl -n demo-app create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username=tilraunastofan \
    --docker-password="${GHCR_PULL_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "ghcr-pull secret ready in demo-app"
}

main "$@"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/registry-secret-up.sh
```

- [ ] **Step 3: Verify script syntax**

Run: `bash -n scripts/registry-secret-up.sh`
Expected: no output, exit code 0

- [ ] **Step 4: Commit**

```bash
git add scripts/registry-secret-up.sh
git commit -m "feat: add registry-secret-up.sh for ghcr-pull imagePullSecret"
```

---

## Task 12: build-and-push.sh

**Files:**
- Create: `scripts/build-and-push.sh`

**Interfaces:**
- Consumes: `demo-apps/event-generator/Dockerfile` (Task 6), `scripts/lib.sh`.
- Produces: a pushed image at `ghcr.io/tilraunastofan/kind-lab/event-generator:<git-short-sha>` — the tag Task 14 manually copies into `helm/event-generator/values.yaml`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Builds the event-generator image, tags it with the current git short SHA,
# and pushes it to ghcr.io. Requires a prior `docker login ghcr.io` using a
# write:packages-scoped token (the user's own machine-level auth — this
# script never handles that credential itself, unlike registry-secret-up.sh
# which does take a token as input, because that one has to hand the
# credential *into* the cluster).
#
# Tagging by git short SHA (rather than something like `latest`) gives every
# build a unique, traceable identifier: you can always answer "which commit
# produced the image currently running in the cluster" by reading
# helm/event-generator/values.yaml's image.tag and looking that SHA up in
# `git log`. This is also exactly the kind of unambiguous, immutable
# version string Kargo (sub-project 3b) will need to promote a specific
# build from dev to "prod" rather than just re-pulling a mutable tag.

IMAGE="ghcr.io/tilraunastofan/kind-lab/event-generator"
APP_DIR="${SCRIPT_DIR}/../demo-apps/event-generator"

main() {
  require_cmd docker git

  local tag
  tag="$(git -C "${SCRIPT_DIR}/.." rev-parse --short HEAD)"

  if ! git -C "${SCRIPT_DIR}/.." diff --quiet -- "${APP_DIR}" || ! git -C "${SCRIPT_DIR}/.." diff --cached --quiet -- "${APP_DIR}"; then
    warn "uncommitted changes under demo-apps/event-generator — the pushed image will not exactly match any commit"
  fi

  log "building ${IMAGE}:${tag}"
  docker build -t "${IMAGE}:${tag}" "${APP_DIR}"

  log "pushing ${IMAGE}:${tag} (requires prior 'docker login ghcr.io' with a write:packages-scoped token)"
  docker push "${IMAGE}:${tag}"

  log "pushed ${IMAGE}:${tag}"
  # Deliberately not automated: this script builds and publishes the
  # artifact, but does NOT edit values.yaml/commit/push itself — that
  # separation (build vs. deploy) is exactly the boundary Kargo will later
  # own end-to-end. Doing it manually once here, per the spec, is what
  # proves out the mechanism Kargo automates in sub-project 3b.
  log "next: set helm/event-generator/values.yaml image.tag to '${tag}', commit, and push to main"
}

main "$@"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/build-and-push.sh
```

- [ ] **Step 3: Verify script syntax**

Run: `bash -n scripts/build-and-push.sh`
Expected: no output, exit code 0

- [ ] **Step 4: Commit**

```bash
git add scripts/build-and-push.sh
git commit -m "feat: add build-and-push.sh for the event-generator image"
```

---

## Task 13: Documentation updates

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update README.md's "Demo apps and vendor charts" section**

Replace:
```markdown
#### Demo apps and vendor charts

- One Go application that generates dummy data and generates low load automatically.
  High load can be enabled via the apps' web UI or API endpoint.
  The Go app saves data to Clickhouse.

- Clickhouse chart vendored with a custom lab-scoped `values.yaml`
```
with:
```markdown
#### Demo apps and vendor charts

- `demo-apps/event-generator` is a Go service that continuously writes
  synthetic events into Clickhouse at a low background rate; a "Trigger
  High Load" button on its web UI (and a `POST /api/load/high` endpoint)
  ramps the insert rate to ~500-1000/sec for a configurable duration. It's
  ArgoCD-managed like everything else, reachable at
  `https://event-generator.lab.test`, and its image is built locally and
  pushed to a private `ghcr.io/tilraunastofan/kind-lab/event-generator`
  package with `scripts/build-and-push.sh` — `helm/event-generator/values.yaml`'s
  `image.tag` is what a human (today) or Kargo (sub-project 3b) bumps to
  roll out a new build. `scripts/registry-secret-up.sh` creates the
  in-cluster pull secret.

- Clickhouse is `bitnami/clickhouse` (not a vendored chart, despite this
  doc's earlier wording), deployed via ArgoCD like every other third-party
  chart in this repo — a multi-source Application pairing the remote chart
  with this repo's lab-scoped `helm/clickhouse/values.yaml`.
```

- [ ] **Step 2: Update README.md's "Task targets" and prerequisites if needed**

Check whether `docker` is already listed among `bootstrap.sh`'s
`require_cmd` — it is (see the "Prerequisites" section, `docker` is
already in the authoritative list) — so no change needed there. No new
Task targets are added by this sub-project (build-and-push and
registry-secret-up are run manually per the spec, not wired into `task
cluster:up`); leave `Taskfile.yaml` and the "Task targets" section as-is.

- [ ] **Step 3: Update CLAUDE.md's stale "images must be kind load'ed" line and add sub-project 3a status**

In `CLAUDE.md`, under "Intent (from README.md)", change:
```markdown
- **Cluster**: `kind`; images must be `kind load`'ed into the cluster rather than pulled from a registry.
```
to:
```markdown
- **Cluster**: `kind`; cluster infra images are `kind load`'ed, but demo-app images are pulled from a private `ghcr.io` registry (see Sub-project 3a below) — the local Docker registry container this line originally referred to was removed.
```

Then add a new paragraph to the "Project status" section (after the
sub-project 2 paragraph) once Task 14's end-to-end verification has
actually passed:
```markdown
Sub-project 3a, demo app + Clickhouse, is complete and working. `demo-apps/event-generator` is a Go service writing synthetic events into Clickhouse at a low background rate with a UI/API-triggered high-load burst; it's deployed as an ArgoCD-managed app (`gitops/apps/event-generator.yaml`, `gitops/apps/clickhouse.yaml`) reachable at `https://event-generator.lab.test`. Images build locally and push to a private `ghcr.io/tilraunastofan/kind-lab/event-generator` package via `scripts/build-and-push.sh`; `helm/event-generator/values.yaml`'s `image.tag` is bumped manually today (sub-project 3b, Kargo, automates this). Verified end-to-end: ArgoCD synced both Applications Healthy, `https://event-generator.lab.test` served the UI over a trusted cert, triggering high load visibly ramped the insert rate, and rows landed in Clickhouse's `events` table.
```

(Leave this last paragraph out of the commit for this task — it belongs
with Task 14 once the verification it describes has actually run. For this
task, commit only the two edits above.)

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: update registry wording for event-generator + clickhouse"
```

---

## Task 14: Manual build, deploy, and end-to-end verification

**Files:** none created; this task executes the scripts and charts from
Tasks 1-13 against the live cluster, then finalizes `CLAUDE.md`.

**Interfaces:** none — this is the spec's "Manual first-build flow", the
sub-project's smoke test.

- [ ] **Step 1: Ensure a `read:packages`-scoped GitHub token is available**

```bash
export GHCR_PULL_TOKEN="<a read:packages-scoped GitHub PAT>"
```

If you don't have one, create it at https://github.com/settings/tokens with
only the `read:packages` scope, scoped to the `tilraunastofan` org/packages
as needed.

- [ ] **Step 2: Create the pull secret**

```bash
./scripts/registry-secret-up.sh
```

Expected: `ghcr-pull secret ready in demo-app` logged, no errors.

- [ ] **Step 3: Build and push the image**

```bash
./scripts/build-and-push.sh
```

Expected: image builds, pushes successfully, and the script prints the
short-SHA tag to use next.

- [ ] **Step 4: Bump the image tag, commit, and push to main**

```bash
git checkout main
git pull
```

Edit `helm/event-generator/values.yaml`, setting `image.tag` to the SHA
printed in Step 3.

```bash
git add helm/event-generator/values.yaml
git commit -m "chore(event-generator): bump image tag to <sha>"
git push origin main
```

- [ ] **Step 5: Wait for ArgoCD to sync both Applications**

```bash
kubectl -n argocd get applications clickhouse event-generator -w
```

Expected: both reach `Synced`/`Healthy`. If `event-generator` is
`Progressing` because its pod is crash-looping waiting on Clickhouse, that
resolves once `clickhouse`'s sync-wave `-1` Application finishes first —
give it a few minutes. Press Ctrl-C once both are `Synced`/`Healthy`.

- [ ] **Step 6: Verify the UI loads over trusted HTTPS**

```bash
curl -sSf https://event-generator.lab.test/healthz
open https://event-generator.lab.test
```

Expected: `curl` returns `200` with no `-k`/`--insecure` flag needed (real
trusted cert, matching the bar set by sub-projects 1 and 2); the browser
shows the event-generator page with no certificate warning.

- [ ] **Step 7: Trigger high load and confirm the rate visibly ramps**

Click "Trigger High Load" in the browser, or:

```bash
curl -sSf -X POST https://event-generator.lab.test/api/load/high
```

Expected: `{"highLoad":true}` returned; watch the Deployment's logs for a
visibly increased insert cadence during the configured
`HIGH_LOAD_DURATION_SECONDS` window, then a return to baseline:

```bash
kubectl -n demo-app logs deploy/event-generator -f --since=1m
```

- [ ] **Step 8: Confirm rows are landing in Clickhouse**

```bash
kubectl -n demo-app exec -it deploy/clickhouse -- clickhouse-client -q "SELECT count() FROM demo.events"
```

(Adjust the pod selector/exec target to whatever the bitnami chart actually
names its pod/container — check with `kubectl -n demo-app get pods` first
if `deploy/clickhouse` doesn't match.)

Expected: a nonzero, growing count across repeated runs of the same query a
few seconds apart.

- [ ] **Step 9: Finalize CLAUDE.md's sub-project 3a status paragraph**

Add the "Sub-project 3a... Verified end-to-end..." paragraph drafted in
Task 13 Step 3 to `CLAUDE.md`'s "Project status" section, now that Steps
5-8 above have actually confirmed it.

```bash
git add CLAUDE.md
git commit -m "docs: mark sub-project 3a (demo app + clickhouse) complete"
git push origin main
```

---

## Self-Review Notes

- **Spec coverage:** background inserter cadence (Task 1/5), event schema
  (Task 2/3), `GET /` UI (Task 4), `POST /api/load/high` with
  extend-not-stack semantics (Task 1/4), `GET /healthz` readiness (Task
  4/5/7), repo layout (Tasks 1-12 match the spec's tree exactly), Clickhouse
  chart/values (Task 8), registry move to ghcr.io + both scripts (Tasks
  11-12), Gateway listener + Certificate + HTTPRoute (Tasks 7/9), namespace
  and sync-wave conventions (Tasks 7/8/10), manual first-build flow (Task
  14), README/CLAUDE.md wording corrections (Task 13) — all covered.
- **Out of scope confirmed excluded:** no dev/prod split, no promotion
  pipeline, no auto-editing of `image.tag` — none of Tasks 1-14 build these.
- **Type consistency check:** `EventInserter` (Task 3) is the interface
  name used consistently in Tasks 4 and 5; `RateController`/`NewRateController`
  (Task 1) match across Tasks 4 and 5; `Event`/`GenerateEvent` (Task 2)
  match in Tasks 3 and 5; `newMux(rc, ready)` signature in Task 4 matches
  its call site in Task 5.
