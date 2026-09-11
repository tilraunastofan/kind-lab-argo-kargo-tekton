# Sub-project 3a: Demo App (Event Generator) + Clickhouse — Design

**Status:** Approved for planning
**Depends on:** Sub-project 2 (ArgoCD GitOps), complete.
**Precedes:** Sub-project 3b (Kargo promotion) — Kargo needs a real, versioned image to promote; this sub-project builds it.

## Goal

Build a minimal Go service ("event generator") that continuously writes
synthetic events into a Clickhouse database at a low background rate, with
a web UI and API to trigger a temporary high-load burst. Deploy it as an
ArgoCD-managed app at `https://event-generator.lab.test`, image built
locally and pushed to a private GitHub Container Registry package. This
gives Kargo (sub-project 3b) something real to promote between dev and
"prod" stages.

## App behavior

- On startup, a background goroutine inserts one synthetic `events` row
  into Clickhouse every ~200-1000ms (randomized within that range) —
  columns: `timestamp` (DateTime64), `event_type` (String, randomly chosen
  from a small fixed set e.g. `page_view`/`click`/`purchase`/`error`),
  `value` (Float64, random), `user_id` (UInt32, random).
- `GET /` serves a single static HTML page showing the current insert rate
  and a "Trigger High Load" button (plain HTML + a few lines of JS calling
  the API below — no frontend framework, no build step).
- `POST /api/load/high` (also triggered by the UI button) ramps the insert
  rate to ~500-1000 events/sec for a configurable duration (env var
  `HIGH_LOAD_DURATION_SECONDS`, default `30`), then returns to baseline.
  Concurrent triggers extend/reset the duration rather than stacking
  multiple ramps.
- `GET /healthz` returns 200 once the Clickhouse connection is established
  (used as the Deployment's readiness/liveness probe).

## Repo layout

```
demo-apps/
  event-generator/
    main.go              # HTTP server, background inserter, load-ramp logic
    go.mod / go.sum
    Dockerfile            # multi-stage: build static binary, copy into distroless/alpine
    static/index.html      # the single-page UI
helm/
  clickhouse/
    values.yaml            # lab-scoped overrides for bitnami/clickhouse
  event-generator/
    Chart.yaml
    values.yaml             # image repository/tag placeholders, env vars
    templates/
      deployment.yaml
      service.yaml
gitops/
  apps/
    clickhouse.yaml         # multi-source: bitnami/clickhouse chart + $values
    event-generator.yaml    # single-source: helm/event-generator (this repo)
scripts/
  build-and-push.sh         # docker build, tag with git short SHA, push to ghcr.io
  registry-secret-up.sh     # creates/refreshes the imagePullSecret from a
                             # read:packages-scoped token
```

## Clickhouse

`bitnami/clickhouse` chart (`https://charts.bitnami.com/bitnami`, version
`9.4.4`) — a direct single-instance StatefulSet deployment, not the
Altinity operator (unnecessary complexity for a lab with one small table).
Deployed via a multi-source ArgoCD Application (remote chart +
`$values/helm/clickhouse/values.yaml` from this repo), same pattern as
cert-manager/ArgoCD/Headlamp. Despite the README's original "vendored
chart" wording, this sub-project treats it like every other third-party
chart in this repo (README will be updated to match, same as the
GitOps-source-repo language was corrected in sub-project 2).

Lab-scoped values: single replica (no keeper/cluster mode — a lab doesn't
need HA Clickhouse), persistence sized small (a few GB), default database
name `demo`, and the `event-generator` app creates its own `events` table
on startup (`CREATE TABLE IF NOT EXISTS`) rather than requiring a separate
migration mechanism — YAGNI for a lab this size.

## Registry: ghcr.io, not the local Docker registry

The previously-running local `registry` container (`registry:3` on
`localhost:5000`) is removed — it was never wired into kind's containerd
and the lab is moving to a real registry instead. Images push to
`ghcr.io/tilraunastofan/kind-lab/<image>:<git-short-sha>`
(`git rev-parse --short HEAD` at build time), private packages.

- `scripts/build-and-push.sh`: `docker build`, tag with the short SHA,
  `docker push` — requires local `docker login ghcr.io` using a
  `write:packages`-scoped token (the user manages this outside the repo,
  same as `gh auth` is already assumed configured for the GitOps deploy-key
  flow).
- `scripts/registry-secret-up.sh`: creates/updates a
  `kubernetes.io/dockerconfigjson` Secret (`ghcr-pull`) in the
  `demo-app` namespace, built from a `read:packages`-scoped token — not
  committed to Git, same secrets-handling pattern as the ArgoCD repo-creds
  Secret from sub-project 2. Idempotent, safe to re-run.
- `helm/event-generator/templates/deployment.yaml` references
  `imagePullSecrets: [{name: ghcr-pull}]`.

## Deployment

- Namespace: `demo-app` (single namespace for now — Kargo's dev/prod stage
  split is sub-project 3b's job, not built prematurely here).
- `gitops/apps/event-generator.yaml`: single-source Application pointing at
  `helm/event-generator` in this repo, `syncOptions: [CreateNamespace=true]`,
  same `automated`/`retry`/sync-wave conventions as every other app.
  `helm/event-generator/values.yaml` holds the image repository and a
  `imageTag` value — **this value is what a human (today) or Kargo (in
  sub-project 3b) updates to roll out a new build**; `build-and-push.sh`
  does not auto-edit it.
- Exposed via the shared Gateway: `helm/gateway/values.yaml` gets one more
  `listeners` entry (`event-generator` / `event-generator.lab.test` /
  `event-generator-tls`), a `Certificate` + `HTTPRoute` under
  `helm/event-generator/extras/`, same pattern as Headlamp.
- `clickhouse` Application gets `sync-wave: "-1"` alongside `cert-manager`
  (event-generator's Deployment will crash-loop on startup until
  Clickhouse exists, but won't block other apps' sync — no hard dependency
  needed beyond ordering CRD-less resources sensibly). `event-generator`
  itself gets `sync-wave: "1"` (after Clickhouse and cert-manager).

## Manual first-build flow (this sub-project's "smoke test")

1. `scripts/registry-secret-up.sh` (creates the pull secret).
2. `scripts/build-and-push.sh` (builds, tags with current short SHA, pushes).
3. Update `helm/event-generator/values.yaml`'s `imageTag` to that SHA, commit, push to `main`.
4. ArgoCD syncs; verify `https://event-generator.lab.test` loads, the insert
   rate is visible, `POST /api/load/high` visibly ramps it, and
   `clickhouse-client`/a port-forward shows rows landing in the `events`
   table.

This manual "bump the tag, commit, push" step is deliberately what Kargo
automates in sub-project 3b — building it manually once here proves the
mechanism Kargo will take over.

## Out of scope (deferred to sub-project 3b, Kargo)

- Any dev/prod stage split, promotion pipeline, or approval gating.
- Automating the image-tag bump in `helm/event-generator/values.yaml`.
- A "prod" Clickhouse or event-generator instance.
