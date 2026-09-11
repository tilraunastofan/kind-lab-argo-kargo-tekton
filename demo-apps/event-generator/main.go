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

	// Both optional — an empty user connects unauthenticated (fine for a
	// bare local ClickHouse container with no auth configured); in the
	// cluster the Deployment always sets both, since the bitnami chart
	// always requires its auto-generated admin password.
	user := os.Getenv("CLICKHOUSE_USER")
	password := os.Getenv("CLICKHOUSE_PASSWORD")

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
	client, err := NewClickhouseClient(ctx, addr, user, password)
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
