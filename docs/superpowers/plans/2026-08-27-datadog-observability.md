# Sub-project 4: Observability with Datadog — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the Datadog Operator and a `DatadogAgent` custom resource, ArgoCD-managed like everything else in this repo, so the kind-lab cluster reports infrastructure metrics to Datadog's EU site — automatically, on every `task cluster:up`.

**Architecture:** Two ArgoCD Applications sync-wave-ordered the same way `clickhouse-operator`/`clickhouse` already are in this repo: `datadog-operator` (remote Helm chart, installs the `DatadogAgent` CRD) at an early wave, `datadog-agent` (a small local chart templating one `DatadogAgent` CR) at a later wave. A new `scripts/datadog-secret-up.sh`, wired into `bootstrap.sh`, creates the API-key Secret the CR references — never committed to Git.

**Tech Stack:** Helm (chart `datadog/datadog-operator` v2.25.1 from `https://helm.datadoghq.com`), the Datadog Operator's `DatadogAgent` CRD (`datadoghq.com/v2alpha1`), ArgoCD Applications, bash (matching `scripts/lib.sh`'s existing helpers).

**Spec:** `docs/superpowers/specs/2026-08-27-datadog-observability-design.md`

## Global Constraints

- Datadog site: `datadoghq.eu` (this org's region — matches the existing Datadog MCP config).
- Cluster name tag: `kind-lab`.
- Namespace for everything Datadog-related: `datadog`.
- `datadog-operator` chart version: `2.25.1` (confirmed current via `helm search repo datadog/datadog-operator --versions` on 2026-08-27).
- No `DATADOG_APP_KEY`/`app-key` anywhere — infra-metrics-only scope, no feature needs it.
- Every new YAML/script file gets educational inline comments explaining *why*, matching the style already established in `scripts/registry-secret-up.sh` and `helm/clickhouse/templates/clickhousecluster.yaml` — this is a learning lab.
- Verification bar: a full `cluster:down` + `cluster:up` cold rebuild, same as sub-projects 1 and 2.

---

### Task 1: `scripts/datadog-secret-up.sh`

**Files:**
- Create: `scripts/datadog-secret-up.sh`

**Interfaces:**
- Consumes: `DATADOG_API_KEY` environment variable (already required per README; not committed to Git). `scripts/lib.sh`'s `log`, `die`, `require_cmd` functions (already exist, used unchanged).
- Produces: a `datadog` namespace and a `datadog-secret` Secret (key `api-key`) in the cluster. Task 3's `DatadogAgent` CR references this exact Secret name/key via `spec.global.credentials.apiSecret.{secretName: datadog-secret, keyName: api-key}`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the datadog-secret Secret in the datadog namespace,
# which helm/datadog-agent's DatadogAgent custom resource
# (spec.global.credentials.apiSecret) references so the Node Agent and
# Cluster Agent can authenticate to Datadog's intake API. Requires
# DATADOG_API_KEY in the environment (not committed to Git — the README
# documents this as a required local env var the cluster is free to use
# directly).
#
# Why a plain kubectl-created Secret instead of a Helm-templated one (the
# way helm/clickhouse/templates/secret.yaml handles the ClickHouse admin
# password): a Datadog API key is a real credential to a third-party SaaS,
# not a lab-only default that's "fine to commit for a fully local
# cluster" — it must never end up in Git, so it can't live in any chart's
# values.yaml or stringData at all. This script creates it out-of-band,
# the exact same way registry-secret-up.sh creates the ghcr-pull
# imagePullSecret from GHCR_PULL_TOKEN.

main() {
  require_cmd kubectl

  if [ -z "${DATADOG_API_KEY:-}" ]; then
    die "DATADOG_API_KEY is not set — export your Datadog API key first"
  fi

  # Same idempotency trick as registry-secret-up.sh: `kubectl create`
  # rendered client-side (--dry-run=client — "print the YAML this would
  # create, don't talk to the apiserver") piped into `apply` creates on
  # the first run and updates in place (e.g. if the key ever rotates) on
  # every run after, instead of failing with "already exists" on a rerun.
  log "ensuring datadog namespace exists"
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing datadog-secret in datadog"
  kubectl -n datadog create secret generic datadog-secret \
    --from-literal=api-key="${DATADOG_API_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "datadog-secret ready in datadog"
}

main "$@"
```

- [ ] **Step 2: Make it executable and syntax-check it**

```bash
chmod +x scripts/datadog-secret-up.sh
bash -n scripts/datadog-secret-up.sh
```

Expected: no output (bash `-n` only checks syntax, prints nothing on success).

- [ ] **Step 3: Run it for real against the live kind-lab cluster**

`DATADOG_API_KEY` should already be set in your shell (it's a documented prerequisite for this repo). Run:

```bash
./scripts/datadog-secret-up.sh
```

Expected output: `ensuring datadog namespace exists`, `creating/refreshing datadog-secret in datadog`, `datadog-secret ready in datadog` — then verify:

```bash
kubectl -n datadog get secret datadog-secret -o jsonpath='{.data.api-key}' | base64 -d | wc -c
```

Expected: a nonzero character count (the decoded key length), confirming the Secret holds real data.

- [ ] **Step 4: Verify re-running is safe (idempotency)**

```bash
./scripts/datadog-secret-up.sh
echo "exit code: $?"
```

Expected: same three log lines, `exit code: 0` — no "already exists" error.

- [ ] **Step 5: Commit**

```bash
git add scripts/datadog-secret-up.sh
git commit -m "feat(datadog): add datadog-secret-up.sh for API key bootstrapping"
```

---

### Task 2: `gitops/apps/datadog-operator.yaml`

**Files:**
- Create: `gitops/apps/datadog-operator.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the `datadog-operator` Deployment running in the `datadog` namespace, and — critically — the `DatadogAgent` CRD (`datadoghq.com/v2alpha1`) registered cluster-wide. Task 3's `datadog-agent` Application depends on this CRD existing before its sync-wave runs.

- [ ] **Step 1: Write the Application manifest**

```yaml
# gitops/apps/datadog-operator.yaml
#
# Installs the Datadog Operator, whose job is to watch for DatadogAgent
# custom resources and turn each one into a running Node Agent DaemonSet +
# Cluster Agent Deployment. Installing the Operator also registers the
# DatadogAgent CRD (datadoghq.com/v2alpha1) that gitops/apps/datadog-agent.yaml
# instantiates in this repo.
#
# Split into its own Application for the same CRD-before-CR ordering
# reason clickhouse-operator.yaml is split from clickhouse.yaml: the
# operator and its CRD must exist and be registered before ArgoCD attempts
# to apply any DatadogAgent resource, and ArgoCD's sync-wave ordering is
# the mechanism that guarantees that.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: datadog-operator
  namespace: argocd
  annotations:
    # "-2" — same tier as clickhouse-operator: both Applications exist
    # solely to register a CRD ahead of anything that instantiates it.
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: https://helm.datadoghq.com
    chart: datadog-operator
    targetRevision: 2.25.1
  destination:
    server: https://kubernetes.default.svc
    namespace: datadog
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

- [ ] **Step 2: Validate the manifest is well-formed YAML**

```bash
kubectl apply --dry-run=client -f gitops/apps/datadog-operator.yaml
```

Expected: `application.argoproj.io/datadog-operator configured (dry run)` or `created (dry run)` — no parse errors. (This only validates YAML/schema shape against the Application CRD already installed by ArgoCD; it does not sync anything.)

- [ ] **Step 3: Apply it directly to the live cluster and watch it sync**

```bash
kubectl apply -f gitops/apps/datadog-operator.yaml
kubectl -n argocd get application datadog-operator -w
```

Expected: `SYNC STATUS` reaches `Synced`, `HEALTH STATUS` reaches `Healthy`. Press Ctrl-C once both are green.

- [ ] **Step 4: Confirm the CRD landed**

```bash
kubectl get crd datadogagents.datadoghq.com
```

Expected: the CRD is listed (confirms Task 3 has something to instantiate).

- [ ] **Step 5: Commit**

```bash
git add gitops/apps/datadog-operator.yaml
git commit -m "feat(datadog): add datadog-operator ArgoCD Application"
git push origin main
```

(Pushing here matters: this repo's `root-app` runs with `selfHeal: true` — anything applied directly to the cluster in Step 3 that isn't also in Git gets reverted on the next reconciliation. Pushing makes the change match what's already live.)

---

### Task 3: `helm/datadog-agent` chart + `gitops/apps/datadog-agent.yaml`

**Files:**
- Create: `helm/datadog-agent/Chart.yaml`
- Create: `helm/datadog-agent/values.yaml`
- Create: `helm/datadog-agent/templates/datadogagent.yaml`
- Create: `gitops/apps/datadog-agent.yaml`

**Interfaces:**
- Consumes: the `DatadogAgent` CRD from Task 2 (must exist before this Application's sync-wave runs). The `datadog-secret` Secret from Task 1 (`spec.global.credentials.apiSecret.secretName: datadog-secret`, `keyName: api-key`).
- Produces: a running Node Agent DaemonSet + Cluster Agent Deployment in the `datadog` namespace, reporting to `datadoghq.eu` tagged `clusterName: kind-lab`. Task 5's verification queries Datadog's own host inventory for these.

- [ ] **Step 1: Write the chart scaffold**

```yaml
# helm/datadog-agent/Chart.yaml
#
# This chart doesn't wrap a remote/vendored chart — it just templates one
# resource, the DatadogAgent custom resource the Datadog Operator
# (gitops/apps/datadog-operator.yaml) reconciles into an actual running
# Node Agent + Cluster Agent. Same "local chart owning our own resources"
# pattern as helm/clickhouse, helm/gateway, and helm/cluster-issuer.
apiVersion: v2
name: datadog-agent
description: DatadogAgent CR for the Datadog Operator
version: 0.1.0
```

```yaml
# helm/datadog-agent/values.yaml
name: datadog

# Must match this repo's existing Datadog MCP configuration
# (https://app.datadoghq.eu) — same org, same region. Sending data to the
# wrong site silently reports nowhere useful (Datadog sites are fully
# separate regional deployments, not just a routing label).
site: datadoghq.eu

# Tags every metric/host this cluster reports with a stable identifier, so
# it's distinguishable in Datadog from anything else reporting to the same
# org.
clusterName: kind-lab

# Where scripts/datadog-secret-up.sh (Task 1) put the API key. No app-key
# here on purpose — nothing in this infra-metrics-only setup needs one
# (Monitors/SLOs/the Datadog API would, but this sub-project doesn't touch
# those).
credentialsSecretName: datadog-secret
credentialsSecretKey: api-key
```

```yaml
# helm/datadog-agent/templates/datadogagent.yaml
#
# The DatadogAgent custom resource: this is the entire interface between
# "I want infra metrics in Datadog" and the Operator actually doing it.
# Once ArgoCD applies this, the Operator's controller notices it and
# creates a Node Agent DaemonSet (one pod per node, collects host/container
# metrics) and a Cluster Agent Deployment (aggregates cluster-level state
# like pod counts and Kubernetes events) — this repo declares none of
# those resources directly, the Operator owns creating and updating them.
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: {{ .Values.name }}
  namespace: datadog
spec:
  global:
    site: {{ .Values.site | quote }}
    clusterName: {{ .Values.clusterName | quote }}
    credentials:
      apiSecret:
        secretName: {{ .Values.credentialsSecretName | quote }}
        keyName: {{ .Values.credentialsSecretKey | quote }}
```

- [ ] **Step 2: Render the chart and validate it server-side**

```bash
helm template helm/datadog-agent | kubectl apply --dry-run=server -f -
```

Expected: `datadogagent.datadoghq.com/datadog created (server dry run)` (or `configured`) — no `strict decoding error` (that error is exactly what would show up if a field name were wrong, as it did with `spec.resources` vs. `spec.containerTemplate.resources` on the ClickHouseCluster CRD earlier in this repo's history — this dry-run step is what catches that class of mistake before it reaches Git).

- [ ] **Step 3: Write the ArgoCD Application manifest**

```yaml
# gitops/apps/datadog-agent.yaml
#
# Instantiates the DatadogAgent custom resource (helm/datadog-agent),
# which the Datadog Operator (gitops/apps/datadog-operator.yaml) turns
# into the actual running Node Agent + Cluster Agent.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: datadog-agent
  namespace: argocd
  annotations:
    # "1" — same tier as event-generator and other app-level resources.
    # Comes after datadog-operator's wave "-2" so the DatadogAgent CRD is
    # already registered by the time ArgoCD tries to apply this
    # Application's CR — the same ordering guarantee clickhouse.yaml
    # relies on relative to clickhouse-operator.yaml.
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: helm/datadog-agent
  destination:
    server: https://kubernetes.default.svc
    namespace: datadog
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

- [ ] **Step 4: Apply directly and watch it sync**

```bash
kubectl apply -f gitops/apps/datadog-agent.yaml
kubectl -n argocd get application datadog-agent -w
```

Expected: `Synced`/`Healthy`. Press Ctrl-C once green.

- [ ] **Step 5: Confirm the Agent pods are actually running**

```bash
kubectl -n datadog get pods
```

Expected: one `datadog-cluster-agent-*` pod and one `datadog-agent-*` pod per node (3 nodes in this cluster — control-plane, worker, worker2), all `1/1 Running` (allow a minute or two for images to pull and pods to reach Ready).

- [ ] **Step 6: Commit**

```bash
git add helm/datadog-agent gitops/apps/datadog-agent.yaml
git commit -m "feat(datadog): add datadog-agent chart and ArgoCD Application"
git push origin main
```

---

### Task 4: Wire `datadog-secret-up.sh` into `bootstrap.sh`

**Files:**
- Modify: `bootstrap.sh`

**Interfaces:**
- Consumes: `scripts/datadog-secret-up.sh` from Task 1 (exact script path, no arguments).
- Produces: `bootstrap.sh` calling it automatically on every `task cluster:up`, so Task 5's cold rebuild has the Secret in place before `datadog-agent`'s Application ever tries to sync.

- [ ] **Step 1: Read the current `bootstrap.sh` to confirm the exact insertion point**

```bash
cat bootstrap.sh
```

Confirm the `main()` function currently reads (this is the file as of the previous sub-project's work):

```bash
main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst ssh-keygen gh

  "${SCRIPT_DIR}/stepca-bootstrap.sh"
  "${SCRIPT_DIR}/cloudprovider-bootstrap.sh"
  "${SCRIPT_DIR}/cluster-up.sh"
  "${SCRIPT_DIR}/cilium-up.sh"
  "${SCRIPT_DIR}/argocd-up.sh"

  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip

  "${SCRIPT_DIR}/issuer-up.sh"
  "${SCRIPT_DIR}/dns-bootstrap.sh"
  "${SCRIPT_DIR}/smoke-test.sh"

  log "kind-lab bootstrap complete"
}
```

If it differs from this, stop and re-read this plan's Task 4 against the actual current file before editing — the insertion point below assumes this exact shape.

- [ ] **Step 2: Add the call right after `argocd-up.sh`**

Change:

```bash
  "${SCRIPT_DIR}/argocd-up.sh"

  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip
```

to:

```bash
  "${SCRIPT_DIR}/argocd-up.sh"
  # datadog-secret-up.sh only needs kubectl (no ArgoCD sync involved), so
  # it can run as soon as the cluster exists — placed here, right after
  # ArgoCD comes up, so the datadog-secret Secret always exists before
  # datadog-agent's Application (sync-wave "1") gets anywhere near syncing.
  "${SCRIPT_DIR}/datadog-secret-up.sh"

  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip
```

- [ ] **Step 3: Verify `require_cmd`'s tool list still covers everything used**

`datadog-secret-up.sh` only calls `kubectl`, already in `bootstrap.sh`'s `require_cmd` line — confirm no change is needed there:

```bash
grep "require_cmd" bootstrap.sh
```

Expected: the line still lists `kubectl` (it already does) — no edit needed.

- [ ] **Step 4: Syntax-check the modified file**

```bash
bash -n bootstrap.sh
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(datadog): wire datadog-secret-up.sh into bootstrap.sh"
git push origin main
```

---

### Task 5: Full cold-rebuild verification + docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1-4, plus the live cluster and the Datadog MCP tools (`search_datadog_hosts`) already available in this session.
- Produces: nothing new for later tasks — this is the sub-project's final verification and doc update, the same shape as sub-project 3a's Task 14.

- [ ] **Step 1: Tear down the cluster**

```bash
task cluster:down
```

Expected: completes without error (the existing, unmodified teardown script).

- [ ] **Step 2: Rebuild from cold**

```bash
task cluster:up
```

Expected: completes without error, ending with `kind-lab bootstrap complete` (this now includes the new `datadog-secret-up.sh` step from Task 4 — watch for `datadog-secret ready in datadog` in the output partway through).

- [ ] **Step 3: Confirm both Datadog Applications are Synced/Healthy**

```bash
kubectl -n argocd get applications datadog-operator datadog-agent
```

Expected: both rows show `Synced` and `Healthy`.

- [ ] **Step 4: Confirm the Agent pods are running**

```bash
kubectl -n datadog get pods
```

Expected: one Cluster Agent pod and one Node Agent pod per node, all `1/1 Running`.

- [ ] **Step 5: Confirm the Agent is actually reporting to Datadog**

Not just "Kubernetes thinks the pods are healthy" — query Datadog's own host inventory, the same way the stale-dashboard report that motivated this sub-project was diagnosed:

Use the `search_datadog_hosts` MCP tool with:
```sql
SELECT hostname, cloud_provider, resource_type, os, agent_version, modification_detected_at FROM hosts WHERE hostname LIKE '%kind%' ORDER BY modification_detected_at DESC LIMIT 20
```

Expected: at least one row per kind-lab node (`kind-lab-control-plane`, `kind-lab-worker`, `kind-lab-worker2`, or however the Agent tags them), with `modification_detected_at` within the last few minutes.

If this returns no rows after a few minutes' wait, check Agent logs before concluding something is wrong:

```bash
kubectl -n datadog logs -l app.kubernetes.io/component=agent --tail=50
```

- [ ] **Step 6: Update `CLAUDE.md`'s "Project status" section**

Add a new paragraph after the sub-project 3a paragraph (find it by searching for `Sub-project 3a` in `CLAUDE.md`):

```markdown
Sub-project 4, observability, is complete and working. `task cluster:up` installs the Datadog Operator (`gitops/apps/datadog-operator.yaml`) and a `DatadogAgent` custom resource (`gitops/apps/datadog-agent.yaml`, `helm/datadog-agent`) reporting infrastructure metrics — cluster/node/pod health, CPU, memory — to Datadog's EU site (`https://app.datadoghq.eu`), tagged `clusterName: kind-lab`. `scripts/datadog-secret-up.sh` creates the API-key Secret from the local `DATADOG_API_KEY` env var (never committed to Git), wired into `bootstrap.sh` right after ArgoCD comes up. This has been verified end-to-end via a full `cluster:down` + `cluster:up` teardown/rebuild from a cold cluster, ending with both Datadog Applications `Synced`/`Healthy`, Node Agent + Cluster Agent pods running on every node, and the kind-lab nodes actually appearing in Datadog's host inventory with a recent `modification_detected_at` — the same bar sub-projects 1, 2, and 3a were held to. Log collection, APM traces, and custom dashboards/Monitors are out of scope for now — infra metrics only.
```

- [ ] **Step 7: Update `README.md`'s Observability bullet**

Find the current bullet (search for `Datadog operator shall be installed`) and replace:

```markdown
- Datadog operator shall be installed, it shall be used to deploy the "Cluster Agent", use local env DATADOG_API_KEY to access DD. Doc link: <https://docs.datadoghq.com/containers/datadog_operator/>. We use the EU region: `https://app.datadoghq.eu`. The Datadog MCP is also installed for Claude, but the cluster is free to use the API key.
```

with:

```markdown
- **Observability**: the Datadog Operator (`gitops/apps/datadog-operator.yaml`) deploys a Node Agent + Cluster Agent (`gitops/apps/datadog-agent.yaml`) reporting infra metrics to the EU region (`https://app.datadoghq.eu`), tagged `clusterName: kind-lab`. `scripts/datadog-secret-up.sh` wires in the local `DATADOG_API_KEY` env var as a cluster Secret — never committed. The Datadog MCP is also installed for Claude's own use, separate from the cluster's key.
```

- [ ] **Step 8: Commit the doc updates**

```bash
git add CLAUDE.md README.md
git commit -m "docs: mark sub-project 4 (Datadog observability) complete"
git push origin main
```

## Self-Review Notes

- **Spec coverage:** Two-Application split (Task 2, Task 3) ✓; `datadog-secret-up.sh` modeled on `registry-secret-up.sh` (Task 1) ✓; bootstrap wiring (Task 4) ✓; full cold-rebuild verification incl. Datadog-side confirmation (Task 5) ✓; CLAUDE.md status update (Task 5, Step 6) ✓; README update (Task 5, Step 7 — spec didn't call this out explicitly but sub-project 3a's Task 13/14 precedent updates both docs, and the current README bullet is now factually stale forward-looking language ("shall be installed"), so this task folds that update in too) ✓; commenting standard applied throughout every new file ✓.
- **Placeholder scan:** no TBD/TODO; every step has literal file content or literal commands; chart version pinned to a real, currently-published version (`2.25.1`, confirmed via `helm search repo`); CRD field names confirmed against the actual downloaded chart's CRD schema, not guessed.
- **Type/name consistency:** Secret name `datadog-secret` / key `api-key` used identically in Task 1 (creation), Task 3's `values.yaml` (`credentialsSecretName`/`credentialsSecretKey`) and `templates/datadogagent.yaml` (`spec.global.credentials.apiSecret`). Namespace `datadog` used identically across Task 1, Task 2's Application `destination.namespace` and `CreateNamespace=true`, Task 3's Application `destination.namespace`. Sync-wave `-2` for `datadog-operator` matches `clickhouse-operator`'s existing wave (same tier, no unexplained new number); sync-wave `1` for `datadog-agent` matches `event-generator`'s existing wave.
