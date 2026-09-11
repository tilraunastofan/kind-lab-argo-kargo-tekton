# Forgejo + Tekton (Pipelines-as-Code) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get a push to a Forgejo mirror of this repo (`https://git.local`) to trigger a Tekton `PipelineRun` in the kind-lab cluster via Pipelines-as-Code (PAC), end to end.

**Architecture:** Tekton Pipelines + Pipelines-as-Code install as two ArgoCD-managed Applications sourcing vendored upstream release manifests. PAC's controller is exposed on the existing shared Gateway at `pipelines-as-code.lab.test`. Two new idempotent bootstrap scripts wire Forgejo (repo + webhook) and the in-cluster PAC `Repository` CR together, following this repo's existing `*-up.sh` / `apps-templates` conventions exactly.

**Tech Stack:** Tekton Pipelines v1.16.0, Pipelines-as-Code v0.51.0, ArgoCD, Cilium Gateway API, cert-manager, bash, Forgejo REST API (Gitea-compatible v1).

**Spec:** `docs/superpowers/specs/2026-09-11-forgejo-tekton-design.md`

## Global Constraints

- GitHub Actions (`.github/workflows/ci.yml`) is untouched — this is a separate, independent pipeline.
- Do not reopen the Kargo promotion-approval decision (`docs/superpowers/specs/2026-08-28-kargo-promotion-design.md`) — Forgejo here exists only to drive Tekton.
- Push to the `forgejo` git remote is manual (`git push forgejo main`), not automated/scheduled.
- No Tekton Dashboard, no Tekton Triggers — PAC bundles its own webhook controller.
- Every new script follows the existing idempotency pattern: `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`.
- `FORGEJO_TOKEN` is already exported in the environment; no new manual credential-provisioning step for the user.
- Verification bar for this sub-project is lighter than the full cold-rebuild bar: apply changes to the existing running cluster and verify directly (per the approved spec) — not a `cluster:down`/`cluster:up` cycle.

---

## Task 1: Vendor Tekton Pipelines + Pipelines-as-Code, install as ArgoCD Applications

**Files:**
- Create: `vendor/tekton-pipelines/release.yaml`
- Create: `vendor/pipelines-as-code/release.yaml`
- Create: `gitops/apps/tekton-pipelines.yaml`
- Create: `gitops/apps/pipelines-as-code.yaml`

**Interfaces:**
- Produces: namespace `tekton-pipelines` (Tekton CRDs: `Pipeline`, `Task`, `PipelineRun`, `TaskRun`, etc.) and namespace `pipelines-as-code` (PAC CRD `Repository`, Service `pipelines-as-code-controller` on port 8080 → pod port 8082). Later tasks depend on both namespaces and the `pipelines-as-code-controller` Service existing.

- [ ] **Step 1: Download and vendor the pinned Tekton Pipelines release manifest**

```bash
mkdir -p vendor/tekton-pipelines
curl -sL https://github.com/tektoncd/pipeline/releases/download/v1.16.0/release.yaml \
  -o vendor/tekton-pipelines/release.yaml
grep -c '^kind: CustomResourceDefinition$' vendor/tekton-pipelines/release.yaml
```

Expected: a non-zero count (confirms the file downloaded real CRD content, not an error page).

- [ ] **Step 2: Download and vendor the pinned Pipelines-as-Code release manifest (Kubernetes variant)**

Use `release.k8s.yaml` (not `release.yaml`) — the plain-Kubernetes variant, without the OpenShift `Route` and `ServiceMonitor` resources the default asset includes (a `ServiceMonitor` would fail to apply without the Prometheus Operator CRD, which this cluster doesn't have).

```bash
mkdir -p vendor/pipelines-as-code
curl -sL https://github.com/tektoncd/pipelines-as-code/releases/download/v0.51.0/release.k8s.yaml \
  -o vendor/pipelines-as-code/release.yaml
grep -c '^kind: CustomResourceDefinition$' vendor/pipelines-as-code/release.yaml
grep '^kind: Route$\|^kind: ServiceMonitor$' vendor/pipelines-as-code/release.yaml
```

Expected: non-zero CRD count; the `Route`/`ServiceMonitor` grep prints nothing.

- [ ] **Step 3: Create the tekton-pipelines ArgoCD Application**

```yaml
# gitops/apps/tekton-pipelines.yaml
#
# Installs Tekton Pipelines from a vendored copy of the upstream release
# manifest (no official Helm chart exists) — same "directory source over a
# single vendored file" shape root-app.yaml itself uses for gitops/apps.
# Split into its own Application, one wave ahead of pipelines-as-code.yaml,
# for the same CRD-before-CR reason clickhouse-operator.yaml and
# datadog-operator.yaml are split from what depends on them: Pipelines-as-Code
# creates PipelineRun/TaskRun objects that require Tekton's CRDs to already
# be registered.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-pipelines
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: vendor/tekton-pipelines
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: tekton-pipelines
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

- [ ] **Step 4: Create the pipelines-as-code ArgoCD Application**

```yaml
# gitops/apps/pipelines-as-code.yaml
#
# Installs Pipelines-as-Code (PAC) from a vendored copy of the upstream
# Kubernetes-variant release manifest. One wave after tekton-pipelines.yaml
# — PAC's controller assumes Tekton's CRDs already exist.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pipelines-as-code
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: vendor/pipelines-as-code
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: pipelines-as-code
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

- [ ] **Step 5: Commit and push to GitHub main**

```bash
git add vendor/tekton-pipelines/release.yaml vendor/pipelines-as-code/release.yaml \
  gitops/apps/tekton-pipelines.yaml gitops/apps/pipelines-as-code.yaml
git commit -m "feat: install Tekton Pipelines and Pipelines-as-Code via ArgoCD"
git push origin main
```

- [ ] **Step 6: Verify both Applications sync Healthy on the running cluster**

```bash
kubectl -n argocd get application tekton-pipelines pipelines-as-code -w
```

Expected: both reach `SYNC STATUS: Synced` / `HEALTH STATUS: Healthy` within a few minutes (Ctrl-C once both are green). Then confirm the controller Service exists:

```bash
kubectl -n pipelines-as-code get svc pipelines-as-code-controller
```

Expected: a `ClusterIP` Service with port `8080` in the output.

---

## Task 2: Forgejo webhook + token Secret (`scripts/pac-forgejo-secret-up.sh`)

**Files:**
- Create: `scripts/pac-forgejo-secret-up.sh`
- Modify: `bootstrap.sh`
- Modify: `README.md` (Prerequisites section)

**Interfaces:**
- Consumes: `FORGEJO_TOKEN` env var (already required to be exported per this task's README update).
- Produces: Secret `pac-forgejo-creds` in namespace `pipelines-as-code`, with keys `token` (the Forgejo PAT) and `webhook.secret` (a random shared secret, generated once and stable across reruns). Task 3 reads `webhook.secret` back out of this Secret; Task 4's `Repository` CR references both keys by name.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the pac-forgejo-creds Secret in the pipelines-as-code
# namespace: the Forgejo personal access token PAC's controller uses to
# talk back to the Forgejo API (post commit statuses, fetch PipelineRun
# definitions from the pushed branch), and a webhook shared secret PAC
# uses to validate that incoming webhook deliveries actually came from
# Forgejo (HMAC-SHA256 over the payload). Requires FORGEJO_TOKEN in the
# environment (not committed to Git — same treatment as
# DATADOG_API_KEY/GHCR_PULL_TOKEN).
#
# The webhook secret is generated once and kept stable across reruns
# (rather than regenerated every time) because scripts/forgejo-repo-up.sh
# (Task 3) reads it back out of this same Secret to register the matching
# webhook secret value on the Forgejo side — the two must always agree, or
# PAC silently rejects every webhook delivery.

main() {
  require_cmd kubectl openssl

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first (Repository:Write, Issue:Write scopes)"
  fi

  log "ensuring pipelines-as-code namespace exists"
  kubectl create namespace pipelines-as-code --dry-run=client -o yaml | kubectl apply -f -

  local webhook_secret
  webhook_secret="$(kubectl -n pipelines-as-code get secret pac-forgejo-creds \
    -o jsonpath='{.data.webhook\.secret}' 2>/dev/null | base64 -d || true)"
  if [ -z "${webhook_secret}" ]; then
    log "generating new webhook shared secret"
    webhook_secret="$(openssl rand -hex 20)"
  else
    log "reusing existing webhook shared secret"
  fi

  log "creating/refreshing pac-forgejo-creds in pipelines-as-code"
  kubectl -n pipelines-as-code create secret generic pac-forgejo-creds \
    --from-literal=token="${FORGEJO_TOKEN}" \
    --from-literal=webhook.secret="${webhook_secret}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "pac-forgejo-creds ready in pipelines-as-code"
}

main "$@"
```

```bash
chmod +x scripts/pac-forgejo-secret-up.sh
```

- [ ] **Step 2: Wire into `bootstrap.sh`, right after the other early secret scripts**

In `bootstrap.sh`, after the `registry-secret-up.sh` line and before `wait_for "lab-gateway has a LoadBalancer IP" ...`, add:

```bash
  # Same reasoning as datadog-secret-up.sh/registry-secret-up.sh above:
  # only needs kubectl, so it can run this early too — placed here so
  # pac-forgejo-creds always exists before forgejo-repo-up.sh (which reads
  # its webhook.secret key back out) and pipelines-as-code-config's
  # Application (Task 4) ever sync.
  "${SCRIPT_DIR}/pac-forgejo-secret-up.sh"
```

- [ ] **Step 3: Add `FORGEJO_TOKEN` to README's Prerequisites section**

In `README.md`, extend the existing sentence documenting `DATADOG_API_KEY`/`GHCR_PULL_TOKEN` (around line 64) to also cover `FORGEJO_TOKEN`:

```markdown
Also required: the `DATADOG_API_KEY`, `GHCR_PULL_TOKEN`, and `FORGEJO_TOKEN`
env vars (a Datadog API key, a `read:packages`-scoped GitHub token, and a
Forgejo personal access token with `Repository:Write`/`Issue:Write` scopes
respectively — not binaries on `PATH`) must be exported in your shell before
running `task cluster:up`. None are checked up front — each corresponding
`*-secret-up.sh`/`*-repo-up.sh` script `die`s partway through bootstrap if
its env var is unset.
```

- [ ] **Step 4: Run the script against the running cluster and verify**

```bash
FORGEJO_TOKEN="$FORGEJO_TOKEN" ./scripts/pac-forgejo-secret-up.sh
kubectl -n pipelines-as-code get secret pac-forgejo-creds -o jsonpath='{.data}' | jq 'keys'
```

Expected: `["token", "webhook.secret"]`.

- [ ] **Step 5: Commit**

```bash
git add scripts/pac-forgejo-secret-up.sh bootstrap.sh README.md
git commit -m "feat: add pac-forgejo-secret-up.sh for PAC's Forgejo credentials"
```

---

## Task 3: Forgejo repo + webhook registration (`scripts/forgejo-repo-up.sh`)

**Files:**
- Create: `scripts/forgejo-repo-up.sh`
- Modify: `bootstrap.sh`

**Interfaces:**
- Consumes: `FORGEJO_TOKEN` env var; Secret `pac-forgejo-creds` (key `webhook.secret`) from Task 2 — must run after Task 2's script.
- Produces: a `kind-lab` repository on `https://git.local` mirroring this one; a registered Forgejo webhook on that repo pointed at `https://pipelines-as-code.lab.test`, using the same `webhook.secret` value stored in Kubernetes; a local git remote named `forgejo` pointing at it. Task 4's `Repository` CR references the same repo URL this script prints/creates. Task 6 pushes to the `forgejo` remote this script sets up.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_URL="https://git.local"
FORGEJO_REPO_NAME="kind-lab"

# Ensures a kind-lab repo exists on the user's self-hosted Forgejo instance
# (git.local, on the same LAN), with a webhook registered against it
# pointing at Pipelines-as-Code's controller, and a local `forgejo` git
# remote so `git push forgejo main` can trigger it. Requires FORGEJO_TOKEN
# (a Forgejo personal access token with Repository:Write/Issue:Write
# scopes) and pac-forgejo-creds (Task 2's Secret, for the webhook shared
# secret — the webhook registered here and the Secret PAC reads from must
# agree, or every delivery is silently rejected).
#
# Uses curl directly against Forgejo's REST API (Gitea-API-compatible v1)
# rather than a dedicated CLI — unlike GitHub, there's no `gh`-equivalent
# already a prerequisite in this repo.

forgejo_api() {
  curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

main() {
  require_cmd kubectl curl jq git

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first"
  fi

  log "looking up Forgejo username for the token"
  local owner
  owner="$(forgejo_api "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
  [ -n "${owner}" ] && [ "${owner}" != "null" ] || die "could not determine Forgejo username — check FORGEJO_TOKEN and ${FORGEJO_URL} reachability"

  local repo_url="${FORGEJO_URL}/${owner}/${FORGEJO_REPO_NAME}"

  if forgejo_api "${repo_url%.git}" -o /dev/null 2>/dev/null; then
    log "repo ${owner}/${FORGEJO_REPO_NAME} already exists on ${FORGEJO_URL}, skipping creation"
  else
    log "creating repo ${owner}/${FORGEJO_REPO_NAME} on ${FORGEJO_URL}"
    forgejo_api -X POST "${FORGEJO_URL}/api/v1/user/repos" \
      -d "{\"name\": \"${FORGEJO_REPO_NAME}\", \"private\": true}" >/dev/null
  fi

  log "reading webhook shared secret from pac-forgejo-creds"
  local webhook_secret
  webhook_secret="$(kubectl -n pipelines-as-code get secret pac-forgejo-creds \
    -o jsonpath='{.data.webhook\.secret}' | base64 -d)"
  [ -n "${webhook_secret}" ] || die "pac-forgejo-creds has no webhook.secret key — run pac-forgejo-secret-up.sh first"

  log "checking for an existing webhook on ${owner}/${FORGEJO_REPO_NAME}"
  local existing_hook_id
  existing_hook_id="$(forgejo_api "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}/hooks" \
    | jq -r '.[] | select(.config.url == "https://pipelines-as-code.lab.test") | .id' | head -1)"

  local hook_payload
  hook_payload=$(cat <<EOF
{
  "type": "forgejo",
  "active": true,
  "config": {
    "url": "https://pipelines-as-code.lab.test",
    "content_type": "json",
    "secret": "${webhook_secret}"
  },
  "events": ["push", "pull_request", "issue_comment"]
}
EOF
)

  if [ -n "${existing_hook_id}" ]; then
    log "updating existing webhook (id ${existing_hook_id}) on ${owner}/${FORGEJO_REPO_NAME}"
    forgejo_api -X PATCH \
      "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}/hooks/${existing_hook_id}" \
      -d "${hook_payload}" >/dev/null
  else
    log "registering webhook on ${owner}/${FORGEJO_REPO_NAME}"
    forgejo_api -X POST \
      "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}/hooks" \
      -d "${hook_payload}" >/dev/null
  fi

  log "ensuring local git remote 'forgejo' points at ${repo_url}"
  if git remote get-url forgejo >/dev/null 2>&1; then
    git remote set-url forgejo "${repo_url}.git"
  else
    git remote add forgejo "${repo_url}.git"
  fi

  log "forgejo remote ready: ${repo_url}.git (push with: git push forgejo main)"
}

main "$@"
```

```bash
chmod +x scripts/forgejo-repo-up.sh
```

Note on git auth for the `forgejo` remote: this script points the remote at a plain HTTPS URL (no embedded credentials); `git push forgejo main` will prompt for credentials the first time. If that's too much manual friction once you try Task 6, switch the remote to `https://<owner>:${FORGEJO_TOKEN}@git.local/...` or configure a credential helper — deliberately left as plain HTTPS here rather than assumed, since embedding the token in `.git/config` is a real (if locally-scoped) tradeoff worth deciding explicitly rather than defaulting into.

- [ ] **Step 2: Wire into `bootstrap.sh`, right after `pac-forgejo-secret-up.sh`**

```bash
  "${SCRIPT_DIR}/forgejo-repo-up.sh"
```

- [ ] **Step 3: Run the script against the running cluster and verify**

```bash
FORGEJO_TOKEN="$FORGEJO_TOKEN" ./scripts/forgejo-repo-up.sh
git remote -v | grep forgejo
```

Expected: the repo exists on `https://git.local` (check via the Forgejo web UI or `curl`), a webhook is registered against `https://pipelines-as-code.lab.test`, and `git remote -v` shows the `forgejo` remote.

If `curl` fails with a TLS trust error against `git.local`, that means the Pi's cert isn't in this Mac's trust store the way `lab.test` certs are — re-run with `curl -k` to confirm that's the actual cause, then decide whether to trust the Pi's CA locally (out of scope to pre-solve; note it in the task's completion comment either way).

- [ ] **Step 4: Commit**

```bash
git add scripts/forgejo-repo-up.sh bootstrap.sh
git commit -m "feat: add forgejo-repo-up.sh to register the Forgejo mirror + webhook"
```

---

## Task 4: PAC `Repository` CR, Certificate, and HTTPRoute (`pac-config-up.sh`)

**Files:**
- Create: `helm/pipelines-as-code-config/Chart.yaml`
- Create: `helm/pipelines-as-code-config/values.yaml`
- Create: `helm/pipelines-as-code-config/templates/certificate.yaml`
- Create: `helm/pipelines-as-code-config/templates/httproute.yaml`
- Create: `helm/pipelines-as-code-config/templates/repository.yaml`
- Create: `gitops/apps-templates/pipelines-as-code-config.yaml.tmpl`
- Create: `scripts/pac-config-up.sh`
- Modify: `helm/gateway/values.yaml`
- Modify: `bootstrap.sh`

**Interfaces:**
- Consumes: `pipelines-as-code-controller` Service (Task 1); `pac-forgejo-creds` Secret (Task 2, referenced by name/key from the `Repository` CR, not duplicated); the Forgejo repo owner this task looks up itself via the same `/api/v1/user` call Task 3 uses.
- Produces: `https://pipelines-as-code.lab.test` routable to PAC's controller with a trusted cert; a `Repository` CR in `pipelines-as-code` namespace PAC watches to know which repo/webhook pairing this cluster serves.

- [ ] **Step 1: Add the new listener to the shared Gateway**

In `helm/gateway/values.yaml`, append:

```yaml
  - name: pipelines-as-code
    hostname: pipelines-as-code.lab.test
    certificateRef: pipelines-as-code-tls
```

- [ ] **Step 2: Create the `pipelines-as-code-config` Helm chart skeleton**

```yaml
# helm/pipelines-as-code-config/Chart.yaml
apiVersion: v2
name: pipelines-as-code-config
version: 0.1.0
```

```yaml
# helm/pipelines-as-code-config/values.yaml
# forgejoOwner is supplied at apply time via
# gitops/apps-templates/pipelines-as-code-config.yaml.tmpl (envsubst'd by
# scripts/pac-config-up.sh) — the Forgejo username isn't knowable at
# authoring time, same reasoning cluster-issuer.yaml.tmpl documents for
# STEPCA_HOST.
forgejoOwner: ""
```

- [ ] **Step 3: Certificate template**

```yaml
# helm/pipelines-as-code-config/templates/certificate.yaml
#
# Same shape as helm/event-generator/extras/certificate.yaml: lives in
# lab-gateway (where the Gateway that will reference the resulting Secret
# lives), issued by the existing step-ca ACME ClusterIssuer.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pipelines-as-code-tls
  namespace: lab-gateway
spec:
  secretName: pipelines-as-code-tls
  dnsNames:
    - pipelines-as-code.lab.test
  issuerRef:
    name: step-ca-acme
    kind: ClusterIssuer
```

- [ ] **Step 4: HTTPRoute template**

```yaml
# helm/pipelines-as-code-config/templates/httproute.yaml
#
# Routes pipelines-as-code.lab.test to PAC's controller Service (installed
# by vendor/pipelines-as-code/release.yaml, Task 1) — port 8080, the
# Service's own "http-listener" port. Lives in the pipelines-as-code
# namespace, same as that Service, matching event-generator's HTTPRoute
# pattern (HTTPRoute alongside its backend Service's namespace).
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pipelines-as-code
  namespace: pipelines-as-code
spec:
  parentRefs:
    - name: lab-gateway
      namespace: lab-gateway
      sectionName: https-pipelines-as-code
  hostnames:
    - pipelines-as-code.lab.test
  rules:
    - backendRefs:
        - name: pipelines-as-code-controller
          port: 8080
```

- [ ] **Step 5: Repository CR template**

```yaml
# helm/pipelines-as-code-config/templates/repository.yaml
#
# Tells PAC's controller which Forgejo repo/webhook pairing this cluster
# serves. secret/webhook_secret reference pac-forgejo-creds (Task 2) by
# name and key — this file only ever references that Secret, never
# duplicates its values, so there is exactly one place (Task 2's script)
# that can create a mismatch between the two.
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: kind-lab
  namespace: pipelines-as-code
spec:
  url: "https://git.local/{{ .Values.forgejoOwner }}/kind-lab"
  git_provider:
    type: forgejo
    url: "https://git.local"
    secret:
      name: pac-forgejo-creds
      key: token
    webhook_secret:
      name: pac-forgejo-creds
      key: webhook.secret
```

- [ ] **Step 6: ArgoCD Application template**

```yaml
# gitops/apps-templates/pipelines-as-code-config.yaml.tmpl
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pipelines-as-code-config
  namespace: argocd
  annotations:
    # Wave "1" — depends on tekton-pipelines/pipelines-as-code's CRDs
    # (wave -2/-1) and cert-manager's ClusterIssuer (wave -1) already
    # existing, same tier as event-generator/headlamp/smoke-test.
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: helm/pipelines-as-code-config
    helm:
      values: |
        forgejoOwner: "${FORGEJO_OWNER}"
  destination:
    server: https://kubernetes.default.svc
    namespace: pipelines-as-code
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

- [ ] **Step 7: Write `scripts/pac-config-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_URL="https://git.local"

app_healthy() {
  local sync health
  sync=$(kubectl -n argocd get application pipelines-as-code-config -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application pipelines-as-code-config -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]
}

main() {
  require_cmd kubectl envsubst curl jq

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first"
  fi

  log "looking up Forgejo username for the token"
  export FORGEJO_OWNER
  FORGEJO_OWNER="$(curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
  [ -n "${FORGEJO_OWNER}" ] && [ "${FORGEJO_OWNER}" != "null" ] || die "could not determine Forgejo username"

  log "applying pipelines-as-code-config Application (repo owner: ${FORGEJO_OWNER})"
  envsubst '${FORGEJO_OWNER}' \
    < "${SCRIPT_DIR}/../gitops/apps-templates/pipelines-as-code-config.yaml.tmpl" | kubectl apply -f -

  wait_for "pipelines-as-code-config Application Synced and Healthy" 90 app_healthy
}

main "$@"
```

```bash
chmod +x scripts/pac-config-up.sh
```

- [ ] **Step 8: Wire into `bootstrap.sh`, after `issuer-up.sh` (needs the ClusterIssuer ready) and before `smoke-test.sh`**

```bash
  "${SCRIPT_DIR}/issuer-up.sh"
  "${SCRIPT_DIR}/dns-bootstrap.sh"
  "${SCRIPT_DIR}/pac-config-up.sh"
  "${SCRIPT_DIR}/smoke-test.sh"
```

- [ ] **Step 9: Apply the gateway change and run the new script against the running cluster**

```bash
git add helm/gateway/values.yaml helm/pipelines-as-code-config gitops/apps-templates/pipelines-as-code-config.yaml.tmpl scripts/pac-config-up.sh bootstrap.sh
git commit -m "feat: expose Pipelines-as-Code webhook endpoint and register Repository CR"
git push origin main
FORGEJO_TOKEN="$FORGEJO_TOKEN" ./scripts/pac-config-up.sh
```

- [ ] **Step 10: Verify**

```bash
kubectl -n argocd get application pipelines-as-code-config
kubectl -n pipelines-as-code get repository kind-lab -o yaml
kubectl -n lab-gateway get certificate pipelines-as-code-tls
curl -sv https://pipelines-as-code.lab.test 2>&1 | grep -i "subject:\|SSL certificate verify ok"
```

Expected: Application `Synced`/`Healthy`; the `Repository` object's `spec.url` shows the correct owner; the `Certificate` is `Ready`; the `curl` shows a valid, trusted TLS handshake (a non-2xx HTTP response from PAC's controller itself is fine here — TLS trust is what this step is checking).

---

## Task 5: Minimal PAC-discovered pipeline

**Files:**
- Create: `.tekton/pipelinerun.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks directly (PAC injects clone params at runtime).
- Produces: the `PipelineRun` definition Task 6's push triggers.

- [ ] **Step 1: Write the pipeline**

```yaml
# .tekton/pipelinerun.yaml
#
# Minimal proof-of-concept pipeline — PAC auto-discovers any .tekton/*.yaml
# on the pushed branch. Deliberately not a port of .github/workflows/ci.yml
# (lint/test/build-push stay GitHub Actions' job, per this sub-project's
# spec) — this only needs to prove push -> webhook -> PipelineRun -> pod
# runs.
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: kind-lab-pac-poc-
  annotations:
    # PAC discovers this file because it matches one of these two
    # annotations' event filters — "push to main" mirrors this repo's
    # other CI (.github/workflows/ci.yml also triggers on push to main).
    pipelinesascode.tekton.dev/on-event: "[push]"
    pipelinesascode.tekton.dev/on-target-branch: "[main]"
spec:
  pipelineSpec:
    tasks:
      - name: hello-from-tekton
        taskSpec:
          steps:
            - name: echo-and-list
              image: alpine:3.20
              script: |
                #!/bin/sh
                set -e
                echo "pac says hi from $(hostname)"
                echo "triggered by PAC on kind-lab"
```

Note: this intentionally skips PAC's usual injected `git-clone` step (`{{ repo_url }}`/`{{ revision }}` params) since there's nothing in the repo this pipeline needs to read yet — it only needs to prove the trigger path works. A real clone step is one line to add later (`params: [{name: repo_url, value: "{{ repo_url }}"}, ...]` with the `git-clone` ClusterTask) once this sub-project moves past proof-of-concept.

- [ ] **Step 2: Validate the YAML is well-formed**

```bash
kubectl apply --dry-run=client -f .tekton/pipelinerun.yaml -o yaml >/dev/null && echo "valid"
```

Expected: `valid` (this only checks the YAML is a structurally valid `PipelineRun`, not that PAC's annotations are honored — that's Task 6).

- [ ] **Step 3: Commit**

```bash
git add .tekton/pipelinerun.yaml
git commit -m "feat: add minimal PAC-discovered proof-of-concept pipeline"
```

---

## Task 6: End-to-end verification

**Files:** none (verification only).

**Interfaces:** exercises the full chain built by Tasks 1–5.

- [ ] **Step 1: Push to the Forgejo mirror**

```bash
git push forgejo main
```

If this is the first push and the remote is a plain HTTPS URL (Task 3's note), authenticate with your Forgejo username and `FORGEJO_TOKEN` as the password when prompted.

- [ ] **Step 2: Confirm Forgejo delivered the webhook**

Via the Forgejo web UI: repo → Settings → Webhooks → the `pipelines-as-code.lab.test` hook → Recent Deliveries. Expected: a `push` delivery with a `2xx` response.

- [ ] **Step 3: Confirm a PipelineRun was created and succeeded**

```bash
kubectl -n pipelines-as-code get pipelinerun --sort-by=.metadata.creationTimestamp
kubectl -n pipelines-as-code logs -l tekton.dev/pipelineRun=$(kubectl -n pipelines-as-code get pipelinerun -o jsonpath='{.items[-1:].metadata.name}') --all-containers
```

Expected: the newest `PipelineRun` shows `SUCCEEDED: True`, and the logs contain `pac says hi from ...`.

- [ ] **Step 4: Confirm Forgejo shows the commit status**

Via the Forgejo web UI: the pushed commit on `git.local` shows a PAC-reported status check (pass/fail) — this is PAC's standard behavior and the main user-visible proof the integration works end to end.

- [ ] **Step 5: If the webhook delivery or PipelineRun never appears**

Troubleshooting order, cheapest check first:
1. `kubectl -n pipelines-as-code logs deploy/pipelines-as-code-controller` — look for webhook-signature-mismatch or Forgejo-API-auth errors.
2. Re-check that `pac-forgejo-creds`' `webhook.secret` matches what Task 3 registered on the Forgejo webhook (`curl` the webhook's config back from the Forgejo API — the secret itself isn't returned by the API for security, but the URL/events are, so at least confirm those match).
3. If the controller logs show DNS/connection errors reaching `git.local`, this is the `.local` mDNS-resolution risk flagged in the design spec — check whether the `pipelines-as-code-controller` pod can resolve `git.local` at all (`kubectl -n pipelines-as-code exec deploy/pipelines-as-code-controller -- nslookup git.local` or equivalent), and if not, that becomes its own follow-up task (likely a CoreDNS forward rule or `hostAliases`), not something to guess-fix here.

---

## Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:** none — documentation only, done after Task 6 passes.

- [ ] **Step 1: Update README.md's architecture bullets**

Add a short bullet near the existing GitOps/Promotion bullets describing what this sub-project adds (Tekton + Pipelines-as-Code, triggered from the Forgejo mirror, proof-of-concept scope, GitHub Actions unaffected).

- [ ] **Step 2: Add a new sub-project entry to CLAUDE.md's "Project status" section**

Following the exact style of the existing sub-project paragraphs (what was built, how it was verified, what's still open) — mark the verification bar explicitly as "verified against the existing running cluster" rather than a cold `cluster:down`/`cluster:up` rebuild, per this sub-project's lighter bar.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document Forgejo + Tekton Pipelines-as-Code sub-project"
```

---

## Self-Review Notes

- **Spec coverage:** install scope (Task 1), Gateway exposure (Task 4), repo mirroring + webhook (Task 3), PAC repo registration (Task 4), minimal pipeline (Task 5), verification bar (Task 6), out-of-scope items (GitHub Actions, Kargo, scheduled mirroring, full CI port, Tekton Dashboard/Triggers) — none touched, as required.
- **Webhook secret coordination risk** (flagged in the spec): resolved by making Task 2's script the single source of truth for `webhook.secret`, with Task 3 reading it back rather than generating its own.
- **`.local` mDNS risk** (flagged in the spec): not pre-solved, per the spec's own instruction — Task 6 Step 5 gives a concrete diagnostic path if it surfaces instead of leaving it undocumented.
- **Type/name consistency:** Secret name `pac-forgejo-creds` and its keys `token`/`webhook.secret` are identical across Task 2 (creates), Task 3 (reads `webhook.secret`), and Task 4 (`Repository` CR references both) — checked for drift.
