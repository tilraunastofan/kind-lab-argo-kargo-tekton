# Tekton in the lab

How CI jobs run in this lab, how to start them, and how to see what they did.

## What is installed

| Component | Version | Namespace | Installed by |
|---|---|---|---|
| Tekton Pipelines | v1.16.0 | `tekton-pipelines` | ArgoCD app `tekton-pipelines` (`vendor/tekton-pipelines/release.yaml`) |
| Pipelines-as-Code (PAC) | v0.51.0 | `pipelines-as-code` | ArgoCD app `pipelines-as-code` (`vendor/pipelines-as-code/release.yaml`) |
| PAC `Repository` CR + Ingress | — | `pipelines-as-code` | ArgoCD app `pipelines-as-code-config` (`helm/pipelines-as-code-config`) |
| Tekton Dashboard (read-only) | v0.72.0 | `tekton-pipelines` | ArgoCD app `tekton-dashboard` (`vendor/tekton-dashboard/release.yaml`, Ingress in `helm/tekton-dashboard/extras/`) |

The Dashboard is at **https://tekton.tekton-lab.test**. It is read-only (upstream's
`release.yaml` runs with `--read-only=true`): you can browse runs, tasks and logs,
but not create or delete them from the UI. PAC is configured with
`tekton-dashboard-url`, so the details link on Forgejo commit statuses points at the
run there. Other monitoring is `kubectl`, the optional `tkn` CLI, Forgejo's commit
statuses, and container logs in ClickHouse (see [Monitoring](#monitoring-and-status)).

## How a job gets started

```
git push (GitHub main)
   └─> Forgejo pull-mirror sync (every 10m)   https://git.local
         └─> webhook ──> https://pipelines-as-code.tekton-lab.test
               └─> PAC controller reads .tekton/*.yaml from the pushed commit
                     └─> creates a PipelineRun in namespace pipelines-as-code
                           └─> Tekton runs one pod per task
                                 └─> PAC watcher posts the result back as a
                                     commit status on the Forgejo mirror
```

The repo registered with PAC is `jakob/kind-lab-argo-kargo-tekton` on Forgejo
(`Repository` CR `kind-lab-argo-kargo-tekton`, namespace `pipelines-as-code`).
PipelineRuns it creates live in that same namespace.

### 1. Push to `main` (the normal path)

Any `.tekton/*.yaml` whose annotations match the event is started. Today there
is one, `.tekton/pipelinerun.yaml`:

```yaml
annotations:
  pipelinesascode.tekton.dev/on-event: "[push]"
  pipelinesascode.tekton.dev/on-target-branch: "[main]"
```

```bash
git push origin main          # to GitHub
```

Forgejo mirrors GitHub on a **10 minute** interval, so the run can start up to
10 minutes after the push. To skip the wait, either trigger a mirror sync
(Forgejo UI → repo → Settings → *Synchronize now*) or push straight to the
Forgejo repo (`https://git.local/jakob/kind-lab-argo-kargo-tekton`), which
fires the webhook immediately.

### 2. Adding or changing a pipeline

Put a `PipelineRun` in `.tekton/` (PAC discovers every file there; no
registration needed). Choose when it runs with the annotations:

| Annotation | Meaning |
|---|---|
| `pipelinesascode.tekton.dev/on-event: "[push]"` | push events (use `[pull_request]` for PRs) |
| `pipelinesascode.tekton.dev/on-target-branch: "[main]"` | branch filter (supports globs/regex) |
| `pipelinesascode.tekton.dev/max-keep-runs: "5"` | keep only the last N runs of this pipeline |

Use `generateName:` (not `name:`) so each run gets a unique name. The pipeline
definition is read **from the pushed commit**, so a change takes effect with
the push that contains it.

### 3. Re-running

- **Pull request comments** (if a PipelineRun has `on-event: "[pull_request]"`):
  comment `/retest` (all) or `/test <pipelinerun-name>` on the Forgejo PR.
- **Push events** have no comment to re-trigger. Push another commit
  (`git commit --allow-empty -m "rerun CI" && git push`), or re-deliver the
  webhook: Forgejo → repo → Settings → Webhooks → the PAC hook → *Recent
  deliveries* → *Redeliver*. Note this replays the original payload and has
  proven unreliable for pipeline matching in this lab; an empty commit is more
  dependable.

### 4. Manually, without Git

PAC is only a trigger; the pipelines are plain Tekton. You can run the same
file directly. PAC annotations are ignored by plain `kubectl`:

```bash
kubectl create -f .tekton/pipelinerun.yaml -n pipelines-as-code
```

(`create`, not `apply`, because of `generateName`.) Nothing is posted to
Forgejo for these runs; it is useful for debugging a pipeline without a commit.

## Monitoring and status

### Tekton Dashboard

https://tekton.tekton-lab.test → *PipelineRuns* (all namespaces) → pick a run for
per-task status, step logs and the YAML.

### kubectl

```bash
# All runs, newest last
kubectl -n pipelines-as-code get pipelineruns --sort-by=.metadata.creationTimestamp

# One run, including per-task status and failure reasons
kubectl -n pipelines-as-code describe pipelinerun <name>

# Task-level detail and the pods behind a run
kubectl -n pipelines-as-code get taskruns
kubectl -n pipelines-as-code get pods -l tekton.dev/pipelineRun=<name>

# Logs of a step (container name is step-<step-name>)
kubectl -n pipelines-as-code logs <pod> -c step-<step-name>
kubectl -n pipelines-as-code logs -l tekton.dev/pipelineRun=<name> --all-containers --prefix

# Watch live
kubectl -n pipelines-as-code get pipelineruns -w
```

`SUCCEEDED` column: `True` = passed, `False` = failed, `Unknown` (reason
`Running`) = in progress. `kubectl get pipelinerun <name> -o jsonpath='{.status.conditions[0].message}'`
gives the one-line reason.

### `tkn` CLI (optional, nicer output)

```bash
brew install tektoncd-cli
tkn pipelinerun list -n pipelines-as-code
tkn pipelinerun logs -f -n pipelines-as-code --last
tkn pipelinerun describe -n pipelines-as-code <name>
```

### Forgejo commit status

For runs started by PAC, the watcher posts the result on the commit in the
Forgejo mirror (`https://git.local/jakob/kind-lab-argo-kargo-tekton/commits/branch/main`),
shown as `Pipelines as Code CI / <pipeline> : success|failure|pending`.
Remote from the LAN: use `https://cm4.tail87cd0d.ts.net` over Tailscale.

### The lab status command

`task status` lists ArgoCD app health, unhealthy pods, certificates, endpoint
reachability, and the **last 3 PipelineRuns**.

### Historical logs (ClickHouse)

Pod logs are shipped by Vector to the host ClickHouse (`logs.logs`, 14-day TTL),
so step logs survive after the pod is garbage-collected. Query as the `admin`
user (password in `~/.tokens` as `CLICKHOUSE_LOGS_ADMIN_PASSWORD`):

```bash
docker exec clickhouse-logs clickhouse-client --user admin \
  --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" --query "
  SELECT timestamp, pod, container, message FROM logs.logs
  WHERE namespace = 'pipelines-as-code' AND pod LIKE 'kind-lab-pac-poc-%'
  ORDER BY timestamp DESC LIMIT 50"
```

Tekton step containers are named `step-<name>`.

## Troubleshooting: nothing started after a push

Work down the chain; each link is observable.

1. **Did Forgejo get the commit?** Check the mirror's latest commit at
   `https://git.local/jakob/kind-lab-argo-kargo-tekton`. If not, sync it or
   wait up to 10 minutes.
2. **Did Forgejo send the webhook?** Repo → Settings → Webhooks → *Recent
   deliveries*. A `204` does **not** prove delivery: Forgejo silently drops
   webhooks to private hosts that aren't in `webhook.ALLOWED_HOST_LIST`, and
   logs that only in the Forgejo container's own logs
   (`ssh cm4.local docker logs forgejo`). `scripts/pac-forgejo-trust-up.sh`
   sets this.
3. **Did PAC receive it?**
   `kubectl -n pipelines-as-code logs deploy/pipelines-as-code-controller`.
   Common errors:
   - `x509: certificate signed by unknown authority` calling `https://git.local`
     → the `pac-controller-ca-bundle` ConfigMap is missing or stale. Run
     `scripts/pac-ca-trust-up.sh`, then
     `kubectl -n pipelines-as-code rollout restart deploy pipelines-as-code-controller pipelines-as-code-watcher`.
   - The controller/watcher pods stuck in `ContainerCreating` with
     `configmap "pac-controller-ca-bundle" not found` is the same root cause
     (the pods mount that ConfigMap).
   - No log lines at all → the webhook never arrived (steps 1–2, or
     `https://pipelines-as-code.tekton-lab.test` unreachable from the Pi; check
     `docker exec forgejo curl https://pipelines-as-code.tekton-lab.test`).
4. **Was a PipelineRun created?** `kubectl -n pipelines-as-code get pipelineruns`.
   If PAC logs say no matching pipeline, check the file's `on-event` /
   `on-target-branch` annotations against the event.
5. **Did it start but fail?** `kubectl describe pipelinerun`, then the step logs
   above. Pods pull images through the kind nodes, so image pull failures show
   up as `ImagePullBackOff` on the task pod.
6. **Status not appearing on the commit?** The watcher posts it. Check
   `kubectl -n pipelines-as-code logs deploy/pipelines-as-code-watcher`, and
   that the PAT in `pac-forgejo-creds` (key `token`) is valid.

`pipelines-as-code` Application `Degraded` in ArgoCD usually means the PAC
controller/watcher pods can't start (see the ConfigMap note above).
Re-running `task cluster:up` re-creates the secrets/ConfigMaps via the
idempotent `pac-*-up.sh` scripts.

## Where things live

| What | Path |
|---|---|
| Pipeline definitions | `.tekton/*.yaml` |
| Tekton / PAC install (vendored upstream) | `vendor/tekton-pipelines/`, `vendor/pipelines-as-code/` |
| ArgoCD Applications | `gitops/apps/tekton-pipelines.yaml`, `gitops/apps/pipelines-as-code.yaml` |
| PAC `Repository` CR, Ingress | `helm/pipelines-as-code-config/`, `scripts/pac-config-up.sh` |
| Forgejo repo/webhook/token setup | `scripts/forgejo-repo-up.sh`, `scripts/pac-forgejo-secret-up.sh` |
| Forgejo-side TLS trust and webhook allow-list | `scripts/pac-forgejo-trust-up.sh` |
| PAC-side CA bundle | `scripts/pac-ca-trust-up.sh` |
