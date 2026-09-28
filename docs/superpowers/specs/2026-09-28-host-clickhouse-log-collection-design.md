# Host ClickHouse + cluster-wide log collection — design

Status: **design approved in conversation 2026-09-28 (decisions 1-4); awaiting written-spec review.**

## Goal

Run a ClickHouse server on the Mac (the host), outside the `tekton-lab` kind
cluster, and ship **all container logs from the cluster** into it. Datadog is
temporarily disabled (host-based billing, see commit `1cc3207`), so this gives
the lab a log store that costs nothing. The design must also leave room to
test **Datadog → ClickHouse** later (or another solution), per
https://clickhouse.com/blog/datadog-and-clickhouse-partnership.

Not to be confused with the existing in-cluster ClickHouse
(`gitops/apps/clickhouse.yaml`, `helm/clickhouse`), which holds the
event-generator demo data (`demo.events`). The new host instance is a separate
server for logs only.

## Context

- Cluster: kind `tekton-lab`, 1 control-plane + 2 workers, kindnet CNI,
  ingress-nginx via hostPort on the control-plane.
- The Mac runs OrbStack, not Docker Desktop. **OrbStack gives every container
  its own IP that is directly reachable from the Mac**, not just published
  ports.
- Precedent for "the cluster talks to a service on the Mac": step-ca
  (`scripts/issuer-up.sh` uses the Mac's hostname/port).
- Bootstrap pattern: numbered idempotent scripts under `scripts/`, wired into
  `bootstrap.sh`; in-cluster apps are ArgoCD Applications under `gitops/apps/`
  with charts/values under `helm/`.
- `helm/datadog-agent` still exists, but `gitops/apps/datadog-agent.yaml` is
  gone (disabled).

## Decisions and the options considered

### Decision 1 — How ClickHouse runs on the Mac

| Option | Notes |
|---|---|
| **A. Docker container (chosen)** | `clickhouse/clickhouse-server`, named volume for data. Portable, same tooling as the rest of the repo, start/stop from a `scripts/` script. With OrbStack the container has a directly reachable IP. |
| B. Homebrew native binary under launchd | Least overhead, direct filesystem access. macOS-specific (conflicts with the portability goal in CLAUDE.md), needs a service definition and sudo. |
| C. Native single `clickhouse` binary run by hand | Fine for ad-hoc use, but not reproducible or bootstrappable. |

Why A: user runs OrbStack; matches repo conventions; portable.

### Decision 2 — Log shipper in the cluster

| Option | Notes |
|---|---|
| **A. Vector DaemonSet (chosen)** | `kubernetes_logs` source + native `clickhouse` sink. Also has a `datadog_agent` source, so the Datadog Agent can later be pointed at Vector and logs fanned out to both Datadog and ClickHouse without redesign. Schema is ours to define. |
| B. OpenTelemetry Collector | `filelog` receiver + ClickHouse exporter; creates the OTel-standard `otel_logs` schema; works with ClickStack/HyperDX. More vendor-neutral but more verbose config. Datadog Agent can also export via OTLP. |
| C. Fluent Bit | Lightweight, but its ClickHouse output is weaker (HTTP output plugin). Rejected. |

Why A: cleanest path to the "Datadog → ClickHouse at some point" goal, plus a
simple, well-documented ClickHouse sink.

### Decision 3 — Row shape in ClickHouse

| Option | Notes |
|---|---|
| **A. One flat `logs` table (chosen)** | Columns: `timestamp`, `namespace`, `pod`, `container`, `node`, `stream`, `message`, `labels` (Map). Parsed JSON fields go into a Map/JSON column. MergeTree, partitioned by day, `ORDER BY (namespace, pod, timestamp)`, TTL 14 days (default; adjustable). Easy plain-SQL querying. |
| B. OTel-style `otel_logs` schema | (`Timestamp`, `SeverityText`, `Body`, `ResourceAttributes`, ...). Compatible with ClickStack/HyperDX and the OTel ecosystem; clumsier for hand-written SQL; only pays off if those tools are adopted. |
| C. Datadog-shaped rows | Mirror Datadog log attributes (`host`, `service`, `status`, `ddsource`, `ddtags`). Makes later Datadog↔ClickHouse comparisons apples-to-apples, but ties the schema to Datadog's model. |

Why A: simplest to query; can grow `service`/`status` columns later, and
Vector can remap into shape B or C if needed.

### Decision 4 — Vector's ClickHouse credentials

| Option | Notes |
|---|---|
| **A. Dedicated insert-only `vector` user (chosen)** | Password from a local env var, delivered as a Kubernetes Secret by a `scripts/*-up.sh` (like `datadog-secret-up.sh`). Vector can write but not read or drop logs. |
| B. Passwordless `default` user | Simplest, but anything that can reach the container can read and drop the logs. |

Passwords are **auto-generated into `~/.tokens` if unset** (chosen over
failing like `datadog-secret-up.sh`, which makes the user set them first).

## Future path: Datadog → ClickHouse

Not built now. The intended shape when we do it: re-enable the Datadog Agent
with log collection, configure its logs endpoint to send to Vector's
`datadog_agent` source, and have Vector fan out to the existing ClickHouse
sink (and optionally on to Datadog). Alternatives noted in the partnership
blog and OTel route (Decision 2 option B) remain open.

## Design

### Host side — `scripts/clickhouse-logs-up.sh` (idempotent)

- Runs one `clickhouse-logs` container (`clickhouse/clickhouse-server`, pinned
  tag) attached to the `kind` network, `--restart unless-stopped`, data in
  named volume `clickhouse-logs-data` (survives `cluster:down`), and
  publishes `127.0.0.1:8123` for convenience.
- Creates the `kind` network if missing and re-runs
  `docker network connect kind clickhouse-logs` (covers the unverified
  teardown case).
- Users: `admin` (for the user and scripts) and insert-only `vector`
  (`GRANT INSERT ON logs.logs`). Passwords from
  `CLICKHOUSE_LOGS_ADMIN_PASSWORD` / `CLICKHOUSE_LOGS_VECTOR_PASSWORD`;
  generated and appended to `~/.tokens` when unset. Never committed.
- Applies schema with `CREATE ... IF NOT EXISTS`: `logs.logs`, MergeTree,
  `PARTITION BY toDate(timestamp)`, `ORDER BY (namespace, pod, timestamp)`,
  `TTL 14 days`.
- Taskfile: `logs-db:up`, `logs-db:down` (removes container, keeps the volume
  unless a purge flag is passed).

### Cluster side

- `scripts/vector-secret-up.sh` creates Secret `vector-clickhouse` in
  namespace `logging`. `bootstrap.sh` runs both scripts before ArgoCD syncs
  Vector.
- `gitops/apps/vector.yaml` installs the official Vector Helm chart, Agent
  (DaemonSet) role; config in `helm/vector/values.yaml`, generously commented.
- DaemonSet tolerates the control-plane `NoSchedule` taint so that node's
  logs are collected too.
- Pipeline: `kubernetes_logs` -> `remap` (map to the Decision 3 columns,
  parsed JSON into the Map column) -> `clickhouse` sink at
  `http://clickhouse-logs:8123`.
- Vector's own pod is excluded to avoid a feedback loop.

### Failure behavior

- ClickHouse down: sink retries with backpressure; Vector checkpoints file
  offsets and resumes. Logs rotated away during a long outage are lost
  (acceptable for a lab).
- Container/network detached after a cluster rebuild: re-running
  `clickhouse-logs-up.sh` (wired into `cluster:up`) re-attaches it.

### Verification (same bar as earlier sub-projects)

- `SELECT namespace, count() FROM logs.logs GROUP BY namespace` shows every
  namespace, including `kube-system`.
- The `vector` user can insert but cannot SELECT.
- Stop the container; confirm Vector recovers and resumes.
- Cold `cluster:down` + `cluster:up`; confirm rows land and the data volume
  survived.
- Update `README.md` and `CLAUDE.md`.

## Facts verified while designing

1. **Reachability from pods to the host container — PROBED 2026-09-28
   (throwaway containers, since removed).** Results with OrbStack:
   - A container on the `kind` Docker network is reachable **by container
     name** from kind nodes and from **pods** (TCP connect succeeded; pod
     lookups first try cluster search domains, get NXDOMAIN, then resolve),
     and **by IP from the Mac** (`192.168.97.x`). So one container on the
     `kind` network serves both Vector (in-cluster) and the user's
     `clickhouse-client` on the Mac.
   - A container on the *default* `bridge` network was **not** reachable
     from the Mac by IP in this probe, so default-bridge is not a viable
     fallback.
   - `host.docker.internal` resolves inside nodes (to OrbStack's host
     gateway), so publishing ports on the Mac is a viable fallback.
   - Name resolution from nodes returned an IPv6 address first; use the
     container name and keep ClickHouse listening on both stacks.
   - **Still unverified:** whether `kind delete cluster` (via
     `cluster:down`) removes the `kind` network or detaches the container.
     Mitigation to design in: the up-script idempotently (re)creates the
     network if missing and runs `docker network connect kind <container>`;
     the container uses `--restart unless-stopped` and its own data volume,
     so logs survive cluster rebuilds.
