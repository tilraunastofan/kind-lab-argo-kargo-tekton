# Sub-project 4: Observability with Datadog — Design

**Status:** Approved for planning
**Depends on:** Sub-project 2 (ArgoCD GitOps), complete. Not dependent on
sub-project 3a/3b.

## Goal

Install the Datadog Operator and a `DatadogAgent` custom resource so the
kind-lab cluster reports infrastructure metrics (cluster/node/pod health,
CPU, memory — the Kubernetes/Containers-equivalent of what Datadog's
built-in dashboards already expect) to Datadog's EU site. `task cluster:up`
should bring this up automatically, to the same bar sub-projects 1 and 2
were held to: a full `cluster:down` + `cluster:up` cold rebuild ending with
the Datadog Application(s) `Synced`/`Healthy` and the Agent actually
reporting (verified against Datadog's own host/infra inventory, not just
Kubernetes pod status).

## Scope

**In scope:** infrastructure metrics only — Node Agent + Cluster Agent via
the Operator, no extra configuration beyond credentials/site/cluster name.

**Out of scope (future sub-projects if wanted):** log collection, APM
traces (would require instrumenting `demo-apps/event-generator`), custom
Datadog dashboards, Monitors/SLOs (would need `DATADOG_APP_KEY`, which
this sub-project does not request or wire up).

## Why the Operator, and why not a separate `datadog-agent` Helm chart

The Datadog Operator's own docs (confirmed via `docs.datadoghq.com` and
`github.com/DataDog/datadog-operator`) are explicit: once the Operator is
installed and a `DatadogAgent` custom resource exists, the Operator's
controller deploys both the Node Agent (DaemonSet) and Cluster Agent
(Deployment) itself. There is no separate `datadog-agent` Helm chart to
install alongside it — doing so would be redundant and would fight the
Operator for ownership of the same resources. This sub-project installs
exactly one Helm chart (`datadog/datadog-operator`) and one custom
resource (`DatadogAgent`).

## Repo layout

```
gitops/
  apps/
    datadog-operator.yaml   # Helm source: https://helm.datadoghq.com,
                             # chart datadog-operator, ns datadog,
                             # sync-wave -2 (installs the DatadogAgent CRD)
    datadog-agent.yaml      # local chart helm/datadog-agent, ns datadog,
                             # sync-wave 1 (applies after the CRD exists)
helm/
  datadog-agent/
    Chart.yaml
    values.yaml              # site, clusterName, secret name/key
    templates/
      datadogagent.yaml      # the DatadogAgent CR
scripts/
  datadog-secret-up.sh        # creates/refreshes the datadog-secret
                               # Secret from $DATADOG_API_KEY
```

This mirrors the existing `clickhouse-operator`/`clickhouse` split
(`gitops/apps/clickhouse-operator.yaml` + `gitops/apps/clickhouse.yaml`,
`helm/clickhouse`) — the same CRD-before-CR ordering problem, solved the
same way, by the same sync-wave mechanism already proven in this repo.

## The `datadog-operator` Application

Single-source Application, chart `datadog-operator` from
`https://helm.datadoghq.com`, deployed into a new `datadog` namespace
(`CreateNamespace=true`, same as `clickhouse-operator`). Sync-wave `-2` —
same tier as `clickhouse-operator`, since both exist solely to register a
CRD ahead of anything that instantiates it. No values overrides needed for
an infra-metrics-only install; defaults are fine.

## The `datadog-agent` Application

Local chart, one templated resource:

```yaml
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: datadog
  namespace: datadog
spec:
  global:
    site: datadoghq.eu
    clusterName: kind-lab
    credentials:
      apiSecret:
        secretName: datadog-secret
        keyName: api-key
```

`site: datadoghq.eu` matches this repo's existing Datadog MCP
configuration (`https://app.datadoghq.eu`) — same org, same region.
`clusterName: kind-lab` gives every metric/host a stable tag so this
cluster is identifiable in Datadog alongside whatever else reports to the
same org. Sync-wave `1` — same tier as `event-generator`/other app-level
resources — ensures it applies only after `datadog-operator`'s sync-wave
`-2` has registered the `DatadogAgent` CRD.

## Credentials: `scripts/datadog-secret-up.sh`

Directly modeled on `scripts/registry-secret-up.sh`: reads
`DATADOG_API_KEY` from the environment (never committed — the README
already documents this as a required local env var), fails loudly via
`die` if unset, and uses the same
`kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -`
idempotency trick so it's safe to re-run. Creates the `datadog` namespace
if needed (same `kubectl create namespace ... --dry-run=client | apply`
pattern as `registry-secret-up.sh`) and the `datadog-secret` Secret with
key `api-key`. No `app-key` — this sub-project doesn't use any
Operator/Agent feature that requires an application key.

## Bootstrap wiring

Add `datadog-secret-up.sh` to `bootstrap.sh`, called right after
`argocd-up.sh` (the namespace/Secret creation only needs `kubectl`, not a
synced ArgoCD Application, but placing it here keeps every non-Git-native
credential-bootstrapping step grouped together conceptually, next to
where `issuer-up.sh`/`dns-bootstrap.sh` already live in the flow). Because
it runs via plain `kubectl` before `datadog-agent`'s Application ever
syncs, the Secret always exists by the time the `DatadogAgent` CR
references it — no ordering dependency on ArgoCD sync-wave timing, only on
script order within `bootstrap.sh`.

`require_cmd` in `bootstrap.sh` needs no additions — `datadog-secret-up.sh`
only uses `kubectl`, already required.

## Verification

Full `cluster:down` + `cluster:up` cold rebuild (the same bar sub-projects
1 and 2 were held to), then:

1. `kubectl -n argocd get applications datadog-operator datadog-agent` —
   both `Synced`/`Healthy`.
2. `kubectl -n datadog get pods` — Cluster Agent Deployment and Node Agent
   DaemonSet pods `Running`/`Ready` on every node.
3. Confirm the Agent is actually reporting to Datadog — not just that
   Kubernetes thinks the pods are healthy. Query Datadog's own host
   inventory (the same `search_datadog_hosts` DDSQL query used to
   diagnose the "stale dashboard" report that motivated this sub-project)
   and confirm the kind-lab nodes now appear with a recent
   `modification_detected_at`.

## Commenting standard

This is a learning lab — every new YAML/script file follows sub-project
3a's precedent (see `scripts/registry-secret-up.sh`, `helm/clickhouse/templates/clickhousecluster.yaml`):
inline comments explain *why*, not just what, especially at points a
newcomer to Kubernetes/Datadog would trip on — e.g. why the CRD-before-CR
ordering matters, why the idempotency trick in `datadog-secret-up.sh`
works, why `site` must match the MCP config, why no `app-key` is created.

## CLAUDE.md status update

Once verification passes, add a "Sub-project 4, observability, is
complete and working" paragraph to `CLAUDE.md`'s "Project status"
section, following the same structure as the sub-project 1/2/3a
paragraphs already there.
