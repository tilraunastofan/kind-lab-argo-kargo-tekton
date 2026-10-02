# kind-lab-argo-kargo-tekton

This is the simplified, Tekton/ArgoCD-focused sibling of the original `kind-lab` lab repo. Cilium/Gateway API networking was intentionally dropped in favor of plain `ingress-nginx` — see `docs/superpowers/specs/2026-09-11-simplified-lab-design.md` for the full rationale.

This is a Kubernetes platform engineering lab and experiment bed.

This repository tracks the bootstrap scripts, Helm charts, Taskfile and other
resources needed to maintain the lab and run experiments.

## Tech stack

The main focus is on testing various Kubernetes features and solutions, but we
need some traffic generated in the cluster from our demo app(s) to the in-cluster Clickhouse server.

### Cluster

- `kind` to maintain the cluster, images should be kind load'ed into the kubernetes cluster

- cert-manager to auto-create TLS certificates for all apps. `step ca` is used as a local CA (it should already be added to my macOS system trust store), the cluster's cert-manager get's an intermediate certificate from `step` so TLS trust works.

- ingress is ingress-nginx (a plain Kubernetes Ingress controller); cert-manager solves ACME HTTP-01 challenges through it via cert-manager's ingress-shim, so traffic is real HTTPS end-to-end

#### Cluster GitOps

- ArgoCD for GitOps, from this repository. ArgoCD uses App-of-Apps to maintain all charts and apps - <https://argo-cd.readthedocs.io/en/stable/>. `task cluster:up` installs ArgoCD as part of bootstrap; cert-manager, ingress-nginx, and the smoke-test app are ArgoCD-managed `Application` resources declared statically under `gitops/apps/` in this repo. The step-ca ACME `ClusterIssuer` and dnsmasq are also ArgoCD-managed, but their `Application` manifests are rendered at bootstrap time from templates under `gitops/apps-templates/` (they need host-specific values — the Mac's hostname/step-ca port, and this Mac's LAN IP, the address ingress-nginx's host-mapped ports 80/443 actually answer on — that can't live in a static Git file) and applied directly by `scripts/issuer-up.sh`/`scripts/dns-bootstrap.sh`. `gitops/apps/` and `gitops/apps-templates/` together are the source of truth for what ArgoCD deploys. ArgoCD's own UI is reachable at `https://argocd.tekton-lab.test` over a trusted cert, same as everything else in the lab.

- **CI (proof-of-concept)**: Tekton Pipelines + Pipelines-as-Code, triggered by pushes and pull requests on this repo's standalone copy on Forgejo at `https://git.local` (not GitHub — GitHub Actions is unaffected; GitHub stays ArgoCD's source, so push to both remotes). What's demoed: `git push forgejo <branch>` or opening a PR, then Pipelines-as-Code's webhook-driven discovery matching `.tekton/*.yaml` and running the pipeline, with the result posted back as a commit/PR status. See CLAUDE.md's Project status for the full story, including the environmental bugs it surfaced and how they were fixed. For how to start, monitor and troubleshoot jobs, see [docs/tekton.md](docs/tekton.md).

- Kargo for promotion between dev -> "prod" (fake lab prod), we need a nice dashboard for this.
  - Claude shall evaluate if we need a Git server with Actions enabled (Forgejo), developers shall be able to submit a pull request and request promotions of a tagged Go app release to "prod", fake managers can approve the request and everything should happen automagically after the approval with proper app tests.

- **Observability**: the Datadog Operator (`gitops/apps/datadog-operator.yaml`) deploys a Node Agent + Cluster Agent (`gitops/apps/datadog-agent.yaml`) reporting infra metrics to the EU region (`https://app.datadoghq.eu`), tagged `clusterName: tekton-lab`. `scripts/datadog-secret-up.sh` wires in the local `DATADOG_API_KEY` env var as a cluster Secret — never committed. The Datadog MCP is also installed for Claude's own use, separate from the cluster's key.

#### Demo apps and vendor charts

- `demo-apps/event-generator` is a Go service that continuously writes
  synthetic events into Clickhouse at a low background rate; a "Trigger
  High Load" button on its web UI (and a `POST /api/load/high` endpoint)
  ramps the insert rate to ~500-1000/sec for a configurable duration. It's
  ArgoCD-managed like everything else, reachable at
  `https://event-generator.tekton-lab.test`, and its image is built locally and
  pushed to a private `ghcr.io/tilraunastofan/kind-lab-argo-kargo-tekton/event-generator`
  package with `scripts/build-and-push.sh` — `helm/event-generator/values.yaml`'s
  `image.tag` is what a human (today) or Kargo (sub-project 3b) bumps to
  roll out a new build. `scripts/registry-secret-up.sh` creates the
  in-cluster pull secret.

- Clickhouse runs via the official [ClickHouse Kubernetes
  operator](https://clickhouse.com/blog/clickhouse-kubernetes-operator)
  (`gitops/apps/clickhouse-operator.yaml`), not a vendored/third-party
  Helm chart — the operator reconciles two CRDs (`KeeperCluster`,
  `ClickHouseCluster`) that `helm/clickhouse` templates. (An earlier
  iteration used the `bitnami/clickhouse` chart; Bitnami retired its free
  unauthenticated images in 2025, and the fallback `bitnamilegacy`
  registry is an unmaintained snapshot, so this repo moved to the
  operator instead.)

### Utilities

- `task` and Taskfile.yaml to manage the cluster and bootstrapping, with optional bash scripts that are invoked from the Taskfile for longer jobs.

## Usage

### Prerequisites

`bootstrap.sh` checks for all of these up front and fails fast if any are missing: `kind`, `helm`, `kubectl`, `docker`, `step`, `step-ca`, `go`, `curl`, `openssl`, `security`, `launchctl`, `scutil`, `envsubst`, plus `task` itself to drive the Taskfile. See `bootstrap.sh`'s `require_cmd` call for the authoritative list.

Also required: the `GHCR_PULL_TOKEN` and `FORGEJO_TOKEN` env vars (a
`read:packages`-scoped GitHub token and a Forgejo personal access token with
`Repository:Write`/`Issue:Write` scopes respectively — not binaries on
`PATH`) must be exported in your shell before running `task cluster:up`.
None are checked up front — each corresponding `*-secret-up.sh`/`*-repo-up.sh`
script `die`s partway through bootstrap if its env var is unset.

Datadog is on by default (Free tier covers the single worker node), so
`DATADOG_API_KEY` must be exported. To opt out, export
`DATADOG_ENABLED=false` and move its Applications into
`gitops/apps-disabled/` (see that README).

### Where to start

`https://tekton-lab.test` is the lab's landing page (`helm/landing-page`, `gitops/apps/landing-page.yaml`) — a static page linking to every app below. Everything is served over a real, trusted cert from this Mac's local step-ca, no `-k`/click-through-the-warning needed in a browser that trusts it.

### Task targets

- `task cluster:up` — bootstrap the full lab cluster (step-ca, kind, ArgoCD/GitOps, ingress-nginx, cert-manager, DNS, smoke test).
- `task cluster:down` — tear down the lab cluster.
- `task cluster:status` — quick health check of the cluster.
- `task smoke:test` — re-run just the smoke-test verification.

### First-run interactive steps

On a fresh workstation, `task cluster:up` may stop partway through and print a one-time `sudo` command to run yourself, then exit non-zero — this happens for the one step that needs elevated privileges the script itself shouldn't have:

- trusting the `step ca` root certificate in the macOS System keychain

Run the printed command, then just re-run `task cluster:up` — it picks up where it left off.

### GitOps workflow

The GitOps source repo is `https://github.com/tilraunastofan/kind-lab-argo-kargo-tekton` (private) — ArgoCD's Applications pull from this same repo's `main` branch (whether declared statically under `gitops/apps/` or rendered from `gitops/apps-templates/` at bootstrap time, see "Cluster GitOps" above). Going forward, a `git push` to `main` is what triggers ArgoCD's auto-sync for the Helm charts those Applications reference. Re-running `task cluster:up` only re-applies the root App-of-Apps pointer — it does not redeploy changes to those Applications' own content; ArgoCD's own continuous reconciliation handles that.

### Log collection (Vector → host ClickHouse) — optional, off by default

Disabled while Datadog is being tested. To enable: `git mv gitops/apps-disabled/vector.yaml gitops/apps/`, push, and export `LOGS_ENABLED=true` for `task cluster:up` (or run `task logs-db:up` and `scripts/vector-secret-up.sh` on a running cluster). To disable again, reverse that and delete the `logging` namespace by hand. The rest of this section describes the enabled state.

When enabled, all cluster container logs are shipped to a ClickHouse that runs outside the cluster, as a plain Docker container (`clickhouse-logs`) on this Mac, attached to kind's Docker network (`scripts/clickhouse-logs-up.sh`, run by `task cluster:up` right after the cluster exists). Inside the cluster, a Vector DaemonSet in the `logging` namespace (`gitops/apps/vector.yaml`, `helm/vector`) reads every node's pod log files, including the control-plane node's, and inserts them into `logs.logs`. Vector excludes its own pod's logs so insert errors can't feed back into the table. Design: `docs/superpowers/specs/2026-09-28-host-clickhouse-log-collection-design.md`.

- `task logs-db:up` — start or repair the container (idempotent; re-attaches it to the `kind` network). Needs the cluster to exist, since kind creates that network.
- `task logs-db:down` — remove the container but keep its data volumes (`clickstack-ch-data`, `clickstack-mongo-data`).
- `task logs-db:purge` — delete the container and the data volume, i.e. all stored logs.

The two passwords (`CLICKHOUSE_LOGS_ADMIN_PASSWORD` for the `admin` user, `CLICKHOUSE_LOGS_VECTOR_PASSWORD` for Vector's insert-only `vector` user) are generated automatically into `~/.tokens` on first run; nothing to export by hand. `chmod 600 ~/.tokens` is recommended, and the script warns if it has to append to a group/other-accessible file. To query:

```bash
source ~/.tokens
docker exec -it clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" \
  --query "SELECT timestamp, namespace, pod, message FROM logs.logs ORDER BY timestamp DESC LIMIT 20"
# or over HTTP from the Mac: curl 'http://127.0.0.1:8123/?user=admin&password=...' --data 'SELECT ...'
```

Rows expire after 14 days (table TTL). The data volume survives `task cluster:down`, so logs from before a rebuild are still there afterwards.

Things worth knowing:

- Vector 0.58 turns off `${VAR}` interpolation in its config by default, so `helm/vector/values.yaml` sets `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true` (and `scripts/vector-config-test.sh` sets it too) for the sink's `${CLICKHOUSE_LOGS_VECTOR_PASSWORD}` to be substituted. Without it the literal string is sent as the password and ClickHouse answers 403. The tradeoff is that interpolation then applies to every config value; the alternative is Vector's secret backends.
- The chart's Services are disabled (`service.enabled: false`, `serviceHeadless.enabled: false`): Vector has no network sources or API, and the API server rejects portless Services.
- Logs emitted while the sink was failing (bad password, or a long ClickHouse outage) are dropped, not replayed, because of checkpoint semantics plus log rotation.
- Datadog is re-enabled (2026-10-02). The idea of sending the Datadog Agent's logs through Vector into this ClickHouse is future work only.

### Troubleshooting

- If `https://*.tekton-lab.test` stops resolving or connecting after this Mac's IP changes (e.g. switching Wi-Fi networks), re-run `scripts/dns-bootstrap.sh` — it looks up this Mac's current LAN IP fresh every run and re-points dnsmasq at it.
- If `scripts/argocd-up.sh` times out waiting for ArgoCD Applications to become `Healthy`, check `kubectl -n argocd get applications` for the stuck one, then `kubectl -n argocd get application <name> -o yaml` for its `status.conditions` — the most common first-bootstrap cause is ArgoCD's initial sync racing an existing (script-created) Helm release's ownership metadata; re-applying that one Application's manifest after the first sync usually resolves it (`gitops/apps/<name>.yaml` for the statically-declared ones, or re-running the relevant bootstrap script — `scripts/issuer-up.sh`/`scripts/dns-bootstrap.sh` — for the templated ones).
- If `clickhouse-operator`'s Application fails to sync on a genuinely cold cluster with `metadata.annotations: Too long: may not be more than 262144 bytes` on the `clickhouseclusters.clickhouse.com` CRD, this is the ClickHouseCluster CRD's huge schema colliding with annotation-based resource tracking: even with `ServerSideApply=true` set (`gitops/apps/clickhouse-operator.yaml`), based on what we observed during manual recovery, this predicts client-side apply is still used for a CRD's very first creation (only patches to an already-existing object go through real server-side apply), so the oversized `kubectl.kubernetes.io/last-applied-configuration` annotation it writes on that first create still blows the cap — this hasn't been re-verified on a subsequent from-scratch rebuild with the fix already in place; if a future cold rebuild does NOT hit this, this note is stale and can be removed. Work around it once per cold cluster with `helm template oci://ghcr.io/clickhouse/clickhouse-operator-helm --version 0.0.7 --show-only templates/crd/clickhouseclusters.clickhouse.com.yaml | kubectl apply --server-side -f -`, then let ArgoCD's next sync (or a `kubectl -n argocd annotate application clickhouse-operator argocd.argoproj.io/refresh=hard --overwrite`) patch cleanly on top of it.
