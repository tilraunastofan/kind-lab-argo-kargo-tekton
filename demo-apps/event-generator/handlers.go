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
