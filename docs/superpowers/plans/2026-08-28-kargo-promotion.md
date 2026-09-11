# Sub-project 3b: Promotion with Kargo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate `event-generator` promotion from a new "dev" environment to the existing "prod" environment using Kargo, with a real app-level health check gating dev→prod eligibility and Kargo's native manual approval gating the actual prod promotion.

**Architecture:** Two new ArgoCD-managed operators (Kargo, Argo Rollouts) plus a local `helm/kargo-project` chart declaring a Kargo `Project`/`Warehouse`/`PromotionTask`/two `Stage`s/an `AnalysisTemplate`. A new `demo-app-dev` namespace/Application mirrors the existing `event-generator` deployment. Kargo promotes by committing an updated `image.tag` to a per-environment values file on `main` and pointing the target ArgoCD Application at that exact commit — no new Git branches, no PR flow, matching every other Application in this repo.

**Tech Stack:** Kargo (`oci://ghcr.io/akuity/kargo-charts/kargo` v1.11.2), Argo Rollouts (official chart, for its `AnalysisTemplate` CRD only — no Rollout objects), ArgoCD Applications, Helm, bash.

**Spec:** `docs/superpowers/specs/2026-08-28-kargo-promotion-design.md`

## Global Constraints

- Environments: two namespaces on the existing single kind cluster — `demo-app` (unchanged, this is "prod") and `demo-app-dev` (new).
- Approval: Kargo's native manual approval on the `prod` Stage (`autoPromotionEnabled: false`). No PR flow, no Forgejo.
- Promotion writes land on `main` directly — no new Git branches.
- `imageSelectionStrategy: NewestBuild` on the Warehouse's image subscription — `event-generator`'s tags are git short-SHAs, not semver (confirmed against Kargo's own Go source, `api/v1alpha1/zz_subscription_types.go`).
- Kargo's Git write credential is a second, `--allow-write` SSH deploy key, auto-generated and auto-registered exactly like ArgoCD's (which is deliberately read-only) — no new manual token.
- ClickHouse stays shared between dev and prod (one instance) — a lab-scale simplification.
- Every new YAML/script file carries educational inline comments explaining *why*, matching this repo's established style (`scripts/registry-secret-up.sh`, `helm/clickhouse/templates/clickhousecluster.yaml`, `helm/datadog-agent/values.yaml`).
- Verification bar: full `cluster:down`/`cluster:up` cold rebuild, ending with a real proven promotion (not just "Applications synced").

---

### Task 1: `scripts/kargo-deploy-key-up.sh`

**Files:**
- Create: `scripts/kargo-deploy-key-up.sh`

**Interfaces:**
- Consumes: `scripts/lib.sh`'s `log`/`die`/`require_cmd` (unchanged). `gh` CLI, already required by `bootstrap.sh`.
- Produces: a `kargo.akuity.io/cred-type: git` Secret named `event-generator-repo` in the `kind-lab` namespace (the Kargo Project's namespace — created later by Task 5's `Project`, but a `kubectl create namespace ... --dry-run=client | apply` here makes this script safe to run before or after that). Task 5's `Warehouse`/`Stage` resources rely on this exact Secret existing in `kind-lab` for Git push access.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Generates (if needed) and registers a SECOND SSH deploy key on this repo,
# distinct from argocd-up.sh's — that one is deliberately read-only ("gh
# deploy keys are read-only by default", see argocd-up.sh's own comment),
# but Kargo's promotion mechanism works by *committing* an updated
# image.tag to Git itself, so it needs write access. Wraps the resulting
# private key into a kargo.akuity.io/cred-type: git Secret, the label
# Kargo's controller looks for when a Warehouse/Stage needs Git credentials
# for a repoURL matching this Secret's data.
#
# Mirrors argocd-up.sh's ensure_deploy_key/register_deploy_key functions
# almost exactly — same idempotency reasoning, same gh CLI calls — just a
# different key path/title and --allow-write on registration.

DEPLOY_KEY_PATH="${HOME}/.ssh/kind-lab-kargo"
REPO_SLUG="tilraunastofan/kind-lab"

ensure_deploy_key() {
  if [ -f "${DEPLOY_KEY_PATH}" ]; then
    log "kargo deploy key already exists at ${DEPLOY_KEY_PATH}, skipping generation"
    return 0
  fi
  log "generating kargo deploy key at ${DEPLOY_KEY_PATH}"
  ssh-keygen -t ed25519 -N "" -C "kind-lab-kargo" -f "${DEPLOY_KEY_PATH}" >/dev/null
}

local_deploy_key_fingerprint() {
  ssh-keygen -lf "${DEPLOY_KEY_PATH}.pub" | awk '{print $2}'
}

deploy_key_title_ids() {
  gh api "repos/${REPO_SLUG}/keys" --paginate \
    --jq '.[] | select(.title == "kind-lab-kargo") | .id' 2>/dev/null
}

deploy_key_registered() {
  local id fingerprint remote_fingerprint local_fingerprint
  local_fingerprint="$(local_deploy_key_fingerprint)"
  while IFS= read -r id; do
    [ -z "${id}" ] && continue
    remote_fingerprint=$(gh api "repos/${REPO_SLUG}/keys/${id}" --jq '.key' 2>/dev/null | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')
    [ "${remote_fingerprint}" = "${local_fingerprint}" ] && return 0
  done < <(deploy_key_title_ids)
  return 1
}

register_deploy_key() {
  if deploy_key_registered; then
    log "kargo deploy key already registered on ${REPO_SLUG}, skipping"
    return 0
  fi
  local stale_id
  while IFS= read -r stale_id; do
    [ -z "${stale_id}" ] && continue
    warn "stale deploy key titled kind-lab-kargo on ${REPO_SLUG} doesn't match local key at ${DEPLOY_KEY_PATH}, deleting id ${stale_id}"
    gh repo deploy-key delete "${stale_id}" --repo "${REPO_SLUG}"
  done < <(deploy_key_title_ids)
  log "registering WRITE-enabled deploy key on ${REPO_SLUG}"
  gh repo deploy-key add "${DEPLOY_KEY_PATH}.pub" --repo "${REPO_SLUG}" --title kind-lab-kargo --allow-write
}

main() {
  require_cmd kubectl gh ssh-keygen

  ensure_deploy_key
  register_deploy_key

  log "ensuring kind-lab namespace exists"
  kubectl create namespace kind-lab --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing event-generator-repo git credential Secret in kind-lab"
  kubectl -n kind-lab create secret generic event-generator-repo \
    --from-literal=repoURL="git@github.com:tilraunastofan/kind-lab.git" \
    --from-file=sshPrivateKey="${DEPLOY_KEY_PATH}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml \
    | kubectl apply -f -

  log "kargo git credential ready in kind-lab"
}

main "$@"
```

- [ ] **Step 2: Make it executable and syntax-check it**

```bash
chmod +x scripts/kargo-deploy-key-up.sh
bash -n scripts/kargo-deploy-key-up.sh
```

Expected: no output.

- [ ] **Step 3: Run it for real against the live kind-lab cluster**

```bash
./scripts/kargo-deploy-key-up.sh
```

Expected: generates `~/.ssh/kind-lab-kargo(.pub)` if not present, registers a write-enabled deploy key on GitHub, creates the `kind-lab` namespace, creates the `event-generator-repo` Secret. Verify:

```bash
kubectl -n kind-lab get secret event-generator-repo -o jsonpath='{.metadata.labels}'
```

Expected: includes `"kargo.akuity.io/cred-type":"git"`.

```bash
gh api repos/tilraunastofan/kind-lab/keys --jq '.[] | select(.title=="kind-lab-kargo") | {id, read_only}'
```

Expected: `read_only: false`.

- [ ] **Step 4: Verify re-running is safe (idempotency)**

```bash
./scripts/kargo-deploy-key-up.sh; echo "exit: $?"
```

Expected: all three "already exists/registered/refreshing" log lines, `exit: 0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/kargo-deploy-key-up.sh
git commit -m "feat(kargo): add kargo-deploy-key-up.sh for write-enabled Git credential"
```

---

### Task 2: `scripts/kargo-image-cred-up.sh`

**Files:**
- Create: `scripts/kargo-image-cred-up.sh`

**Interfaces:**
- Consumes: `GHCR_PULL_TOKEN` (already a required env var, used identically by `registry-secret-up.sh`).
- Produces: a `kargo.akuity.io/cred-type: image` Secret named `event-generator-image` in the `kind-lab` namespace. Task 5's `Warehouse` relies on this to authenticate to the private `ghcr.io/tilraunastofan/kind-lab/event-generator` package when listing tags.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the Secret Kargo's Warehouse uses to authenticate to
# the private ghcr.io/tilraunastofan/kind-lab/event-generator package when
# checking for new image tags. Reuses GHCR_PULL_TOKEN — already a required
# env var for scripts/registry-secret-up.sh's ghcr-pull imagePullSecret —
# rather than asking for yet another token; both Secrets grant the same
# read:packages-scoped access, just in the shape each consumer expects
# (Kubernetes' dockerconfigjson for kubelet image pulls vs. Kargo's own
# plain username/password Secret shape for its own image-tag-listing API
# calls).

main() {
  require_cmd kubectl

  if [ -z "${GHCR_PULL_TOKEN:-}" ]; then
    die "GHCR_PULL_TOKEN is not set — export a read:packages-scoped GitHub token first"
  fi

  log "ensuring kind-lab namespace exists"
  kubectl create namespace kind-lab --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing event-generator-image credential Secret in kind-lab"
  kubectl -n kind-lab create secret generic event-generator-image \
    --from-literal=repoURL="ghcr.io/tilraunastofan/kind-lab/event-generator" \
    --from-literal=username="tilraunastofan" \
    --from-literal=password="${GHCR_PULL_TOKEN}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - kargo.akuity.io/cred-type=image -o yaml \
    | kubectl apply -f -

  log "kargo image credential ready in kind-lab"
}

main "$@"
```

- [ ] **Step 2: Make it executable and syntax-check it**

```bash
chmod +x scripts/kargo-image-cred-up.sh
bash -n scripts/kargo-image-cred-up.sh
```

Expected: no output.

- [ ] **Step 3: Run it for real against the live cluster**

`GHCR_PULL_TOKEN` should already be set (a documented prerequisite). Run:

```bash
./scripts/kargo-image-cred-up.sh
kubectl -n kind-lab get secret event-generator-image -o jsonpath='{.metadata.labels}'
```

Expected: includes `"kargo.akuity.io/cred-type":"image"`.

- [ ] **Step 4: Verify idempotency**

```bash
./scripts/kargo-image-cred-up.sh; echo "exit: $?"
```

Expected: `exit: 0`, no errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/kargo-image-cred-up.sh
git commit -m "feat(kargo): add kargo-image-cred-up.sh for GHCR image credential"
```

---

### Task 3: Install Kargo and Argo Rollouts operators

**Files:**
- Create: `scripts/kargo-admin-up.sh`
- Create: `gitops/apps/kargo.yaml`
- Create: `gitops/apps/argo-rollouts.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a `kargo-admin` Secret in namespace `kargo` (must exist before Kargo's `kargo-api` Deployment can start healthy — see Step 1). The `kargo-controller`/`kargo-api`/`kargo-webhooks-server` Deployments running in namespace `kargo`, plus the `Project`/`Warehouse`/`Stage`/`PromotionTask` CRDs registered. The `argo-rollouts` Deployment running in namespace `argo-rollouts`, plus the `AnalysisTemplate`/`AnalysisRun` CRDs registered. Task 5 instantiates the Project/Warehouse/Stages; Task 7 logs into Kargo using this Secret's password.

- [ ] **Step 1: Write and run `scripts/kargo-admin-up.sh` — Kargo's admin account credential**

Unlike every other operator installed so far in this repo, Kargo's Helm chart does **not** auto-generate an admin account: `api.adminAccount.passwordHash` (a bcrypt hash) and `api.adminAccount.tokenSigningKey` must either be set directly in Helm values (which would mean committing a password hash to Git — avoid this) or sourced from an existing Secret via `api.secret.name` (confirmed via `helm show values oci://ghcr.io/akuity/kargo-charts/kargo --version 1.11.2`, `api.secret.name`'s own description: "Specifies the name of an existing Secret which contains the `ADMIN_ACCOUNT_PASSWORD_HASH` and `ADMIN_ACCOUNT_TOKEN_SIGNING_KEY` values"). This script creates that Secret out-of-band, the same pattern as `datadog-secret-up.sh`/`registry-secret-up.sh`.

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates Kargo's admin-account Secret (kargo-admin, in the kargo
# namespace) so its API server has something to authenticate against.
# Kargo's own Helm chart (unlike every other chart this repo installs)
# does not auto-generate this — see gitops/apps/kargo.yaml's
# api.secret.name override, which points the chart at this exact Secret
# instead of requiring a password hash inlined into Git-committed values.
#
# Only generates a new random password the FIRST time (i.e. if this Secret
# doesn't already exist) — a full `cluster:down`+`cluster:up` always
# destroys and recreates the whole cluster anyway, so there's nothing to
# preserve across a cold rebuild; but re-running this script against a
# cluster that's already up (e.g. bootstrap.sh re-run after a partial
# failure) must NOT invalidate a password the user may have already
# copied down.
#
# htpasswd -bnBC 10 "" <password> is Kargo's own documented method for
# generating this exact bcrypt hash format (confirmed against Kargo's
# quickstart docs) — the leading empty username ("") and -n (no colon
# prefix written to a file) just make htpasswd emit ":<hash>" to stdout,
# which the `cut` below strips down to the hash alone.

main() {
  require_cmd kubectl htpasswd openssl

  log "ensuring kargo namespace exists"
  kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f -

  if kubectl -n kargo get secret kargo-admin >/dev/null 2>&1; then
    log "kargo-admin Secret already exists in kargo, leaving it as-is"
    return 0
  fi

  local password password_hash token_signing_key
  password="$(openssl rand -base64 18 | tr -d '=+/')"
  password_hash="$(htpasswd -bnBC 10 "" "${password}" | cut -d: -f2)"
  token_signing_key="$(openssl rand -base64 29 | tr -d '=+/')"

  kubectl -n kargo create secret generic kargo-admin \
    --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="${password_hash}" \
    --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="${token_signing_key}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "kargo-admin Secret created — Kargo admin password (save this now, it will not be shown again): ${password}"
}

main "$@"
```

```bash
chmod +x scripts/kargo-admin-up.sh
bash -n scripts/kargo-admin-up.sh
./scripts/kargo-admin-up.sh
```

Expected first run: `kargo-admin Secret created — Kargo admin password (save this now, it will not be shown again): <random string>` — **write this password down**, Task 7 needs it. Verify:

```bash
kubectl -n kargo get secret kargo-admin -o jsonpath='{.data.ADMIN_ACCOUNT_PASSWORD_HASH}' | base64 -d
```

Expected: a `$2y$10$...`-shaped bcrypt hash. Re-run the script once more and confirm it logs "already exists" rather than generating a second password.

- [ ] **Step 2: Write the Kargo Application manifest**

```yaml
# gitops/apps/kargo.yaml
#
# Installs Kargo (https://kargo.io), ArgoCD's sibling promotion tool —
# Kargo automates rolling a new event-generator image from "dev" to the
# existing "prod" (gitops/apps/event-generator.yaml), gated by a real
# app-level health check and a human's manual approval. Kargo requires
# ArgoCD to already be installed (it drives promotions by committing to
# Git and then pointing an existing ArgoCD Application at the new commit —
# see gitops/apps/kargo-project.yaml's PromotionTask).
#
# No sync-wave override: nothing else in gitops/apps/ depends on Kargo's
# CRDs being ready before its own default wave, unlike clickhouse-operator
# or datadog-operator (kargo-project.yaml, Task 5, gets an explicit later
# wave instead, the same CRD-before-CR ordering already used twice in this
# repo).
#
# helm.values below points the chart at the kargo-admin Secret Step 1
# creates, rather than inlining a bcrypt password hash into this
# Git-committed file — api.secret.name is exactly the escape hatch the
# chart's own values.yaml documents for this ("the Secret will not be
# generated by Helm").
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kargo
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: ghcr.io/akuity/kargo-charts
    chart: kargo
    targetRevision: 1.11.2
    helm:
      values: |
        api:
          secret:
            name: kargo-admin
  destination:
    server: https://kubernetes.default.svc
    namespace: kargo
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

- [ ] **Step 3: Write the Argo Rollouts Application manifest**

```yaml
# gitops/apps/argo-rollouts.yaml
#
# Installs Argo Rollouts (https://argo-rollouts.readthedocs.io) — used
# here ONLY for its AnalysisTemplate/AnalysisRun CRDs, which Kargo's Stage
# verification mechanism is built on. event-generator does NOT become an
# Argo Rollouts Rollout object; AnalysisTemplate/AnalysisRun work standalone
# against a plain Deployment, running one Job/HTTP check and reporting
# success/failure back to whatever (here, Kargo) is watching the resulting
# AnalysisRun.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.39.4
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts
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

- [ ] **Step 4: Confirm the Argo Rollouts chart version is current**

```bash
helm repo add argo https://argoproj.github.io/argo-helm 2>&1 | tail -2
helm repo update argo 2>&1 | tail -2
helm search repo argo/argo-rollouts --versions 2>&1 | head -3
```

If the top listed version differs from `2.39.4`, update Step 3's `targetRevision` to match before proceeding — this plan's version was current as of 2026-08-28.

- [ ] **Step 5: Validate both manifests, apply directly, watch them sync**

```bash
kubectl apply --dry-run=client -f gitops/apps/kargo.yaml
kubectl apply --dry-run=client -f gitops/apps/argo-rollouts.yaml
kubectl apply -f gitops/apps/kargo.yaml -f gitops/apps/argo-rollouts.yaml
kubectl -n argocd get application kargo argo-rollouts -w
```

Expected: both dry-runs succeed with no parse errors; both Applications reach `Synced`/`Healthy`. Press Ctrl-C once both are green.

- [ ] **Step 6: Confirm the CRDs landed**

```bash
kubectl get crd projects.kargo.akuity.io warehouses.kargo.akuity.io stages.kargo.akuity.io promotiontasks.kargo.akuity.io
kubectl get crd analysistemplates.argoproj.io analysisruns.argoproj.io
```

Expected: all six CRDs listed.

- [ ] **Step 7: Commit**

```bash
git add scripts/kargo-admin-up.sh gitops/apps/kargo.yaml gitops/apps/argo-rollouts.yaml
git commit -m "feat(kargo): install Kargo and Argo Rollouts operators"
git push origin main
```

(Push here matters, same reasoning as every prior sub-project: this repo's `root-app` runs with `selfHeal: true`.)

---

### Task 4: New `demo-app-dev` environment

**Files:**
- Modify: `helm/event-generator/templates/deployment.yaml`
- Modify: `helm/event-generator/templates/service.yaml`
- Modify: `helm/event-generator/values.yaml`
- Create: `helm/event-generator/values-dev.yaml`
- Create: `helm/event-generator/extras-dev/certificate.yaml`
- Create: `helm/event-generator/extras-dev/httproute.yaml`
- Modify: `helm/gateway/values.yaml`
- Modify: `scripts/registry-secret-up.sh`
- Create: `gitops/apps/event-generator-dev.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `demo-app-dev` namespace with a running `event-generator` Deployment reachable at `https://event-generator-dev.lab.test`, using the same shared ClickHouse instance in `demo-app`. Task 5's `dev` Stage promotes into `helm/event-generator/values-dev.yaml`'s `image.tag`; its `AnalysisTemplate` targets `https://event-generator-dev.lab.test/healthz`.

- [ ] **Step 1: Templatize the hardcoded `namespace` field in the chart**

`helm/event-generator/templates/deployment.yaml` and `templates/service.yaml` both currently hardcode `namespace: demo-app` in their `metadata`. A Helm-templated resource's own `metadata.namespace` takes precedence over the ArgoCD Application's `destination.namespace` — so simply pointing a new Application at this same chart with a different `destination.namespace` would silently keep deploying into `demo-app` instead of `demo-app-dev`. Parameterize it.

In `helm/event-generator/templates/deployment.yaml`, change:
```yaml
metadata:
  name: event-generator
  namespace: demo-app
```
to:
```yaml
metadata:
  name: event-generator
  namespace: {{ .Values.namespace }}
```

In `helm/event-generator/templates/service.yaml`, change:
```yaml
metadata:
  name: event-generator
  namespace: demo-app
```
to:
```yaml
metadata:
  name: event-generator
  namespace: {{ .Values.namespace }}
```

- [ ] **Step 2: Add the default `namespace` value, preserving prod's existing behavior**

Add to `helm/event-generator/values.yaml` (this is "prod" — stays `demo-app`):
```yaml
# Templated (see templates/deployment.yaml, templates/service.yaml) so the
# same chart can deploy into a second namespace for sub-project 3b's "dev"
# environment (values-dev.yaml overrides this to demo-app-dev) without
# duplicating the chart itself.
namespace: demo-app
```

- [ ] **Step 3: Create the dev values override**

```yaml
# helm/event-generator/values-dev.yaml
#
# Overrides ONLY what differs from values.yaml (Helm merges a chart's own
# values.yaml with any additional -f/valueFiles on top, so everything not
# listed here — clickhouseAddr, highLoadDurationSeconds — is inherited
# unchanged; ClickHouse is deliberately shared between dev and prod, a
# lab-scale simplification, not a data-integrity-sensitive prod database).
namespace: demo-app-dev

image:
  tag: "774b747" # starts identical to prod; sub-project 3b's Kargo Stage (Task 5) takes over bumping this independently
```

- [ ] **Step 4: Validate the chart still renders correctly for both environments**

```bash
helm template helm/event-generator | grep -A1 "^  namespace:" | head -4
helm template helm/event-generator -f helm/event-generator/values-dev.yaml | grep -A1 "^  namespace:" | head -4
```

Expected: first command shows `namespace: demo-app` (twice, Deployment + Service); second shows `namespace: demo-app-dev` (twice).

- [ ] **Step 5: Create the dev Certificate and HTTPRoute**

`helm/event-generator/extras/` (prod's) are static raw manifests, not Helm-templated — copy them into a parallel `extras-dev/` directory with dev-specific values, same pattern as every hardcoded field already in the prod versions.

```yaml
# helm/event-generator/extras-dev/certificate.yaml
#
# dev's counterpart to extras/certificate.yaml — same ACME ClusterIssuer,
# different hostname/Secret name so it doesn't collide with prod's cert.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: event-generator-dev-tls
  namespace: lab-gateway
spec:
  secretName: event-generator-dev-tls
  dnsNames:
    - event-generator-dev.lab.test
  issuerRef:
    name: step-ca-acme
    kind: ClusterIssuer
```

```yaml
# helm/event-generator/extras-dev/httproute.yaml
#
# dev's counterpart to extras/httproute.yaml — routes to the Service this
# chart renders in the demo-app-dev namespace (values-dev.yaml's
# namespace override), via the https-event-generator-dev listener
# helm/gateway/values.yaml gains in Step 6 below.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: event-generator
  namespace: demo-app-dev
spec:
  parentRefs:
    - name: lab-gateway
      namespace: lab-gateway
      sectionName: https-event-generator-dev
  hostnames:
    - event-generator-dev.lab.test
  rules:
    - backendRefs:
        - name: event-generator
          port: 80
```

- [ ] **Step 6: Add the dev Gateway listener**

In `helm/gateway/values.yaml`, append (matching the established "onboarding a new app is a one-line values append" pattern):
```yaml
  - name: event-generator-dev
    hostname: event-generator-dev.lab.test
    certificateRef: event-generator-dev-tls
```

- [ ] **Step 7: Extend `registry-secret-up.sh` to cover the new namespace**

`helm/event-generator/templates/deployment.yaml` references `ghcr-pull` as an imagePullSecret — that Secret must exist in whichever namespace the Pod runs in, so `demo-app-dev` needs its own copy too. Change `scripts/registry-secret-up.sh`'s `main()` from:

```bash
main() {
  require_cmd kubectl

  if [ -z "${GHCR_PULL_TOKEN:-}" ]; then
    die "GHCR_PULL_TOKEN is not set — export a read:packages-scoped GitHub token first"
  fi

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
```

to:

```bash
main() {
  require_cmd kubectl

  if [ -z "${GHCR_PULL_TOKEN:-}" ]; then
    die "GHCR_PULL_TOKEN is not set — export a read:packages-scoped GitHub token first"
  fi

  # demo-app-dev (sub-project 3b's Kargo-managed "dev" environment) needs
  # the exact same imagePullSecret demo-app ("prod") already does — same
  # private image, different namespace, and imagePullSecrets only work
  # within the Pod's own namespace, so this can't be shared across the two.
  local ns
  for ns in demo-app demo-app-dev; do
    log "ensuring ${ns} namespace exists"
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -

    log "creating/refreshing ghcr-pull imagePullSecret in ${ns}"
    kubectl -n "${ns}" create secret docker-registry ghcr-pull \
      --docker-server=ghcr.io \
      --docker-username=tilraunastofan \
      --docker-password="${GHCR_PULL_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -

    log "ghcr-pull secret ready in ${ns}"
  done
}
```

- [ ] **Step 8: Create the dev ArgoCD Application**

```yaml
# gitops/apps/event-generator-dev.yaml
#
# "dev" — mirrors gitops/apps/event-generator.yaml exactly (same
# two-source shape: the Helm chart itself, plus a directory source for
# the raw Certificate/HTTPRoute manifests) except it points at
# values-dev.yaml and the demo-app-dev namespace/extras-dev directory.
# Sub-project 3b's Kargo Stage (Task 5) is what actually bumps this
# Application's image tag going forward — see helm/kargo-project.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: event-generator-dev
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  sources:
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      path: helm/event-generator
      helm:
        valueFiles:
          - values-dev.yaml
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      path: helm/event-generator/extras-dev
      directory:
        include: "*.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-app-dev
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

- [ ] **Step 9: Apply everything directly, run the pull-secret script, watch it sync**

```bash
kubectl apply -f gitops/apps/event-generator-dev.yaml
./scripts/registry-secret-up.sh
kubectl -n argocd get application event-generator-dev -w
```

(Applying the Gateway values change requires pushing to Git first — ArgoCD's `gateway` Application syncs from Git, not a local `helm upgrade`, unlike Cilium. Do Step 10's commit/push before expecting `event-generator-dev.lab.test`'s cert to actually issue.)

Expected once pushed and synced: `event-generator-dev` reaches `Synced`/`Healthy`.

- [ ] **Step 10: Commit and push**

```bash
git add helm/event-generator/templates/deployment.yaml helm/event-generator/templates/service.yaml \
  helm/event-generator/values.yaml helm/event-generator/values-dev.yaml \
  helm/event-generator/extras-dev scripts/registry-secret-up.sh \
  helm/gateway/values.yaml gitops/apps/event-generator-dev.yaml
git commit -m "feat(kargo): add demo-app-dev environment for event-generator"
git push origin main
```

- [ ] **Step 11: Verify end-to-end over HTTPS**

```bash
kubectl -n argocd annotate application gateway argocd.argoproj.io/refresh=hard --overwrite
sleep 15
curl -sSf -w "\nHTTP:%{http_code}\n" https://event-generator-dev.lab.test/healthz
```

Expected: `HTTP:200`, no `-k`/`--insecure` needed (real trusted cert, same bar as every other hostname in this repo).

---

### Task 5: Kargo `Project`/`Warehouse`/`PromotionTask`/`Stage`s/`AnalysisTemplate`

**Files:**
- Create: `helm/kargo-project/Chart.yaml`
- Create: `helm/kargo-project/values.yaml`
- Create: `helm/kargo-project/templates/project.yaml`
- Create: `helm/kargo-project/templates/warehouse.yaml`
- Create: `helm/kargo-project/templates/promotiontask.yaml`
- Create: `helm/kargo-project/templates/stage-dev.yaml`
- Create: `helm/kargo-project/templates/stage-prod.yaml`
- Create: `helm/kargo-project/templates/analysistemplate.yaml`
- Create: `gitops/apps/kargo-project.yaml`

**Interfaces:**
- Consumes: Task 1's `event-generator-repo` Secret and Task 2's `event-generator-image` Secret (both in namespace `kind-lab`, referenced by label, not by name, per Kargo's credential-discovery convention). Task 3's `Project`/`Warehouse`/`Stage`/`AnalysisTemplate`/`PromotionTask` CRDs. Task 4's `event-generator-dev` Application (name referenced by the dev Stage's `argocd-update` step) and existing `event-generator` Application (prod).
- Produces: a working promotion pipeline. Task 6 wires credentials into `bootstrap.sh`; Task 7 proves the whole thing end-to-end.

- [ ] **Step 1: Write the chart scaffold**

```yaml
# helm/kargo-project/Chart.yaml
#
# This chart doesn't wrap a remote/vendored chart — it templates the
# Kargo resources (Project, Warehouse, PromotionTask, two Stages, an
# AnalysisTemplate) that drive event-generator's dev->prod promotion.
# Same "local chart owning our own resources" pattern as helm/clickhouse,
# helm/datadog-agent, helm/gateway.
apiVersion: v2
name: kargo-project
description: Kargo Project/Warehouse/Stages for event-generator promotion
version: 0.1.0
```

```yaml
# helm/kargo-project/values.yaml
projectName: kind-lab
imageRepoURL: ghcr.io/tilraunastofan/kind-lab/event-generator
gitRepoURL: git@github.com:tilraunastofan/kind-lab.git
devValuesFile: helm/event-generator/values-dev.yaml
prodValuesFile: helm/event-generator/values.yaml
devHealthzURL: https://event-generator-dev.lab.test/healthz
```

- [ ] **Step 2: Write the Project (dev auto-promotes, prod requires manual approval)**

```yaml
# helm/kargo-project/templates/project.yaml
#
# A Kargo Project is cluster-scoped, but its metadata.name becomes the
# namespace every other Kargo resource for this project lives in — Kargo's
# controller creates and labels that namespace itself (confirmed against
# akuity/kargo-examples' own manifests, which follow this exact pattern).
# promotionPolicies is what actually implements this sub-project's
# approval decision: dev auto-promotes new Freight the moment the
# Warehouse discovers it; prod does not, and can only be promoted via
# `kargo promote` / the Kargo dashboard — Kargo's own native manual
# approval, deliberately chosen over a PR-based flow (see the spec's
# "Scope decisions" section for why).
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: {{ .Values.projectName }}
spec:
  promotionPolicies:
    - stage: dev
      autoPromotionEnabled: true
    - stage: prod
      autoPromotionEnabled: false
```

- [ ] **Step 3: Write the Warehouse**

```yaml
# helm/kargo-project/templates/warehouse.yaml
#
# Watches ghcr.io/tilraunastofan/kind-lab/event-generator for new tags,
# turning each one into Freight the dev Stage can promote. Credentials
# come from the event-generator-image Secret (Task 2) — Kargo discovers
# it by matching the Secret's kargo.akuity.io/cred-type: image label and
# repoURL field against this subscription's repoURL, not by name.
#
# imageSelectionStrategy: NewestBuild (not the default SemVer) because
# event-generator's tags are git short-SHAs (scripts/build-and-push.sh),
# not semantic versions — confirmed against Kargo's own source
# (api/v1alpha1/zz_subscription_types.go): NewestBuild selects by image
# creation timestamp instead of attempting to parse the tag as semver.
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: event-generator
  namespace: {{ .Values.projectName }}
spec:
  subscriptions:
    - image:
        repoURL: {{ .Values.imageRepoURL }}
        imageSelectionStrategy: NewestBuild
```

- [ ] **Step 4: Write the shared PromotionTask**

```yaml
# helm/kargo-project/templates/promotiontask.yaml
#
# One task, reused by both Stages via the valuesFile var they each pass in
# — dev writes values-dev.yaml, prod writes values.yaml (the existing
# file, unchanged path). Pattern adapted from Kargo's own official
# akuity/kargo-examples repo (02-git-driven/02-helm-driven/01-image-only),
# with one deliberate change: this writes straight to main instead of a
# per-stage Git branch — every other Application in this repo lives on
# main only, and Kargo's branch-per-stage default buys nothing at this
# scale. No PR step either (that same example's prod Stage uses
# git-open-pr/git-wait-for-pr) — this sub-project uses Kargo's native
# manual approval instead (see project.yaml).
apiVersion: kargo.akuity.io/v1alpha1
kind: PromotionTask
metadata:
  name: promote-event-generator
  namespace: {{ .Values.projectName }}
spec:
  vars:
    - name: valuesFile
    - name: appName
  steps:
    - uses: git-clone
      config:
        repoURL: {{ .Values.gitRepoURL }}
        checkout:
          - branch: main
            path: ./src
    - uses: yaml-update
      as: update-image
      config:
        path: ./src/${{ "{{" }} vars.valuesFile {{ "}}" }}
        updates:
          - key: image.tag
            value: ${{ "{{" }} imageFrom("{{ .Values.imageRepoURL }}").Tag {{ "}}" }}
    - uses: git-commit
      as: commit
      config:
        path: ./src
        messageFromSteps:
          - update-image
    - uses: git-push
      config:
        path: ./src
    - uses: argocd-update
      config:
        apps:
          - name: ${{ "{{" }} vars.appName {{ "}}" }}
            sources:
              - repoURL: {{ .Values.gitRepoURL }}
                desiredRevision: ${{ "{{" }} outputs.commit.commit {{ "}}" }}
```

**Note on the `${{ "{{" }} ... {{ "}}" }}` escaping above:** Kargo's own expression syntax uses `${{ }}`, which collides with Helm's `{{ }}` templating delimiters. This is a real, well-known conflict, not a plan typo — when writing this file, use Helm's documented escape (`{{ "{{" }}`/`{{ "}}" }}` for the literal braces, or wrap the whole block in a `{{ \`...\` }}` raw string if that reads more clearly) so Helm passes Kargo's `${{ vars.valuesFile }}`-style expressions through to the rendered manifest untouched rather than trying to evaluate them itself. Verify this renders correctly in Step 8 before moving on — this is the single most likely spot for a subtle bug in this task.

- [ ] **Step 5: Write the dev Stage**

```yaml
# helm/kargo-project/templates/stage-dev.yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: dev
  namespace: {{ .Values.projectName }}
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: event-generator
      sources:
        direct: true
  promotionTemplate:
    spec:
      vars:
        - name: valuesFile
          value: {{ .Values.devValuesFile }}
        - name: appName
          value: event-generator-dev
      steps:
        - task:
            name: promote-event-generator
  verification:
    analysisTemplates:
      - name: event-generator-healthz
```

- [ ] **Step 6: Write the prod Stage**

```yaml
# helm/kargo-project/templates/stage-prod.yaml
#
# sources.stages: [dev] means prod can only request Freight that has
# already been promoted to (and passed verification in) dev — it's not
# eligible straight from the Warehouse. Combined with project.yaml's
# autoPromotionEnabled: false for this stage, promotion still requires an
# explicit `kargo promote` / dashboard click even once eligible.
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: prod
  namespace: {{ .Values.projectName }}
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: event-generator
      sources:
        stages:
          - dev
  promotionTemplate:
    spec:
      vars:
        - name: valuesFile
          value: {{ .Values.prodValuesFile }}
        - name: appName
          value: event-generator
      steps:
        - task:
            name: promote-event-generator
```

- [ ] **Step 7: Write the AnalysisTemplate**

```yaml
# helm/kargo-project/templates/analysistemplate.yaml
#
# The "proper app tests" gate the README asks for: an HTTP GET against
# dev's actual running /healthz endpoint via Argo Rollouts' `web` metric
# provider. Confirmed against Argo Rollouts' own source
# (metricproviders/webmetric/webmetric.go): any non-2xx response is
# automatically treated as a measurement error regardless of
# successCondition, so no successCondition is needed here at all — a
# passing check is simply "the endpoint returned 2xx within the timeout."
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: event-generator-healthz
  namespace: {{ .Values.projectName }}
spec:
  metrics:
    - name: healthz
      provider:
        web:
          url: {{ .Values.devHealthzURL }}
```

- [ ] **Step 8: Render and validate the whole chart server-side**

```bash
helm template helm/kargo-project | kubectl apply --dry-run=server -f -
```

Expected: every resource (`project.kargo.akuity.io`, `warehouse.kargo.akuity.io`, `promotiontask.kargo.akuity.io`, two `stage.kargo.akuity.io`, `analysistemplate.argoproj.io`) reports `created (server dry run)` with no strict-decoding error. Pay special attention to the `PromotionTask`'s rendered output — confirm the `${{ vars.valuesFile }}`-style expressions survived Helm's templating literally (not evaluated/mangled), i.e. `helm template helm/kargo-project | grep 'vars\.'` should show them intact.

If the dry-run reports an unknown-field error anywhere, cross-check the exact field name against the live CRD schema the same way this repo has resolved every prior CRD-field mismatch (e.g. `kubectl get crd stages.kargo.akuity.io -o yaml`) before changing anything else.

- [ ] **Step 9: Write the ArgoCD Application**

```yaml
# gitops/apps/kargo-project.yaml
#
# Instantiates helm/kargo-project. Later wave than kargo.yaml/
# argo-rollouts.yaml (Task 3, wave "-2") so their CRDs are registered
# first — same CRD-before-CR ordering already used for
# clickhouse-operator/clickhouse and datadog-operator/datadog-agent.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kargo-project
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: helm/kargo-project
  destination:
    server: https://kubernetes.default.svc
    namespace: kind-lab
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

- [ ] **Step 10: Apply directly, watch it sync**

```bash
kubectl apply -f gitops/apps/kargo-project.yaml
kubectl -n argocd get application kargo-project -w
```

Expected: `Synced`/`Healthy`. Press Ctrl-C once green.

- [ ] **Step 11: Confirm the Kargo resources actually exist and are wired up**

```bash
kubectl -n kind-lab get project,warehouse,stage,promotiontask,analysistemplate
kubectl -n kind-lab get warehouse event-generator -o jsonpath='{.status.conditions}'
```

Expected: all resources listed; the Warehouse's conditions show it successfully discovering Freight (may take a minute — Kargo polls on an interval).

- [ ] **Step 12: Commit**

```bash
git add helm/kargo-project gitops/apps/kargo-project.yaml
git commit -m "feat(kargo): add Project/Warehouse/Stages/AnalysisTemplate for event-generator promotion"
git push origin main
```

---

### Task 6: Wire all three new scripts into `bootstrap.sh`

**Files:**
- Modify: `bootstrap.sh`

**Interfaces:**
- Consumes: `scripts/kargo-admin-up.sh` (Task 3, Step 1), `scripts/kargo-deploy-key-up.sh` (Task 1), and `scripts/kargo-image-cred-up.sh` (Task 2), exact paths, no arguments.
- Produces: all three credentials existing automatically on a cold rebuild — `kargo-admin` before Kargo's own `kargo-api` Pod needs it to start healthy, and the other two before `kargo-project`'s Warehouse/Stages (sync-wave "2") ever try to use them.

- [ ] **Step 1: Read the current `bootstrap.sh` to confirm the exact insertion point**

```bash
cat bootstrap.sh
```

Confirm `main()` currently reads (as of this plan's writing — Tasks 1-5 above don't touch this file):

```bash
main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst ssh-keygen gh

  "${SCRIPT_DIR}/stepca-bootstrap.sh"
  "${SCRIPT_DIR}/cloudprovider-bootstrap.sh"
  "${SCRIPT_DIR}/cluster-up.sh"
  "${SCRIPT_DIR}/cilium-up.sh"
  "${SCRIPT_DIR}/argocd-up.sh"
  # datadog-secret-up.sh only needs kubectl (no ArgoCD sync involved), so
  # it can run as soon as the cluster exists — placed here, right after
  # ArgoCD comes up, so the datadog-secret Secret always exists before
  # datadog-agent's Application (sync-wave "1") gets anywhere near syncing.
  "${SCRIPT_DIR}/datadog-secret-up.sh"
  # Same reasoning as datadog-secret-up.sh above: registry-secret-up.sh
  # only needs kubectl, so it can run this early too — placed here so the
  # ghcr-pull imagePullSecret always exists before event-generator's
  # Application (sync-wave "1") ever tries to pull its image, instead of
  # crash-looping in ImagePullBackOff until someone runs this manually.
  "${SCRIPT_DIR}/registry-secret-up.sh"

  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip

  "${SCRIPT_DIR}/issuer-up.sh"
  "${SCRIPT_DIR}/dns-bootstrap.sh"
  "${SCRIPT_DIR}/smoke-test.sh"

  log "kind-lab bootstrap complete"
}
```

If it differs, stop and re-read this task against the actual current file before editing.

- [ ] **Step 2: Add all three calls after `registry-secret-up.sh`**

Change:
```bash
  "${SCRIPT_DIR}/registry-secret-up.sh"

  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip
```
to:
```bash
  "${SCRIPT_DIR}/registry-secret-up.sh"
  # Same reasoning again: all three kargo-*-up.sh scripts only need
  # kubectl (kargo-deploy-key-up.sh also needs gh, already required
  # above) and no ArgoCD sync, so they can run this early. kargo-admin-up.sh
  # matters most here — without it, gitops/apps/kargo.yaml's Application
  # still reaches Synced (ArgoCD's initial wait_for above only checks
  # sync.status, not health.status) but Kargo's own kargo-api Pod would
  # crash-loop indefinitely with no admin credential to reference. The
  # other two exist before kargo-project's Warehouse/Stages (sync-wave
  # "2", the latest of any Application in this repo) get anywhere near
  # syncing.
  "${SCRIPT_DIR}/kargo-admin-up.sh"
  "${SCRIPT_DIR}/kargo-deploy-key-up.sh"
  "${SCRIPT_DIR}/kargo-image-cred-up.sh"

  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip
```

- [ ] **Step 3: Confirm `require_cmd`'s tool list still covers everything used**

`kargo-admin-up.sh` additionally needs `htpasswd` — check whether it's already available or needs adding to `require_cmd`:

```bash
which htpasswd
grep "require_cmd" bootstrap.sh
```

If `htpasswd` isn't found, or `require_cmd`'s line doesn't already list it, add it to the `require_cmd` line in `main()` (it's a standard macOS-provided binary at `/usr/sbin/htpasswd`, part of Apache tools shipped with the OS — should already be present, but don't assume without checking). `kubectl`, `ssh-keygen`, `gh` are already listed and need no change.

- [ ] **Step 4: Syntax-check**

```bash
bash -n bootstrap.sh
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(kargo): wire kargo-admin-up.sh, kargo-deploy-key-up.sh, kargo-image-cred-up.sh into bootstrap.sh"
git push origin main
```

---

### Task 7: Full cold-rebuild verification + real end-to-end promotion + docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1-6, plus the live cluster and `gh`/`kargo` CLIs.
- Produces: nothing new for later tasks — this sub-project's final verification and doc update, the same shape as sub-project 3a's Task 14 and sub-project 4's Task 5.

- [ ] **Step 1: Install the `kargo` CLI if not already present**

```bash
which kargo || (brew tap akuity/tap && brew install akuity/tap/kargo)
kargo version
```

- [ ] **Step 2: Tear down and rebuild the cluster from cold, capturing the Kargo admin password**

`scripts/kargo-admin-up.sh` (Task 3) only ever prints the plaintext admin password once, to its own log line — it's never retrievable afterward (only the bcrypt hash is stored in the `kargo-admin` Secret). Capture `task cluster:up`'s output this time instead of letting it scroll past:

```bash
task cluster:down
task cluster:up 2>&1 | tee /tmp/cluster-up.log
grep "Kargo admin password" /tmp/cluster-up.log
```

Expected: completes without error (also watch for the `kargo git credential ready`/`kargo image credential ready` log lines, confirming Tasks 1/2/6's wiring worked from cold); the final `grep` prints one line ending in the random password — save it for Step 4.

- [ ] **Step 3: Confirm every new Application is Synced/Healthy**

```bash
kubectl -n argocd get applications kargo argo-rollouts kargo-project event-generator-dev event-generator
```

Expected: all five `Synced`/`Healthy`.

- [ ] **Step 4: Log in to Kargo and confirm the Project is visible**

```bash
kubectl -n kargo port-forward svc/kargo-api 8080:80 &
kargo login https://localhost:8080 --insecure-skip-tls-verify --admin --password "<the password captured in Step 2>"
kargo get projects
```

Expected: `kind-lab` listed.

- [ ] **Step 5: Push a new image and confirm the Warehouse discovers it**

```bash
./scripts/build-and-push.sh
```

Note the printed tag, then:

```bash
kargo get freight --project kind-lab
```

Expected: new Freight listed for the tag just pushed, within a minute or two (Kargo's default Warehouse poll interval).

- [ ] **Step 6: Confirm dev auto-promotes and verification passes**

```bash
kargo get freight --project kind-lab -o wide
kubectl -n demo-app-dev get pods -w
```

Expected: `event-generator` in `demo-app-dev` rolls to the new tag without manual intervention; the Freight's dev verification eventually shows `Successful` (`kargo get analysisruns -n kind-lab` or the dashboard also shows this).

```bash
curl -sSf https://event-generator-dev.lab.test/healthz
```

Expected: `200`, confirming the app-level check the `AnalysisTemplate` itself performed.

- [ ] **Step 7: Confirm prod does NOT auto-promote**

```bash
kubectl -n demo-app get pods -o jsonpath='{.items[0].spec.containers[0].image}'
```

Expected: still the OLD tag — prod has not moved yet.

- [ ] **Step 8: Manually approve the prod promotion**

```bash
kargo promote --project kind-lab --stage prod --freight <freight-id-from-step-5>
```

Expected: the promotion runs; watch it with `kargo get promotions --project kind-lab`.

- [ ] **Step 9: Confirm prod actually rolled**

```bash
kubectl -n demo-app get pods -o jsonpath='{.items[0].spec.containers[0].image}'
curl -sSf https://event-generator.lab.test/healthz
```

Expected: image now shows the new tag; `/healthz` still returns `200` over the existing trusted cert.

- [ ] **Step 10: Update `CLAUDE.md`'s "Project status" section**

Add a new paragraph after the sub-project 4 paragraph:

```markdown
Sub-project 3b, promotion, is complete and working. Kargo (`gitops/apps/kargo.yaml`) and Argo Rollouts (`gitops/apps/argo-rollouts.yaml`, used only for its `AnalysisTemplate` CRD) drive promotion of `event-generator` from a new "dev" environment (`demo-app-dev`, `gitops/apps/event-generator-dev.yaml`, `https://event-generator-dev.lab.test`) to the existing "prod" (`demo-app`, unchanged from sub-project 3a). A `Warehouse` (`helm/kargo-project`) watches `ghcr.io/tilraunastofan/kind-lab/event-generator` for new tags; dev auto-promotes and is gated by a real `AnalysisTemplate` health check against `/healthz`; prod requires a human's explicit approval via `kargo promote` — Kargo's own native manual approval, not a PR-based flow, which is also this repo's answer to the README's open question about needing a self-hosted Forgejo Git server (not needed). Kargo's own admin-account credential and both new Git/image credentials are auto-provisioned by `scripts/kargo-admin-up.sh`/`scripts/kargo-deploy-key-up.sh`/`scripts/kargo-image-cred-up.sh`, wired into `bootstrap.sh`. Verified end-to-end via a full `cluster:down`/`cluster:up` cold rebuild, then a real promotion proven live: a freshly pushed image was auto-promoted to dev, passed its health-check verification, sat correctly un-promoted in prod pending approval, and rolled out to prod immediately after a manual `kargo promote` — the same bar every prior sub-project has been held to.
```

- [ ] **Step 11: Update `README.md`'s Promotion bullet, resolving the Forgejo question**

Find the current bullet (search for `Kargo for promotion`) and replace:

```markdown
- Kargo for promotion between dev -> "prod" (fake lab prod), we need a nice dashboard for this.
  - Claude shall evaluate if we need a Git server with Actions enabled (Forgejo), developers shall be able to submit a pull request and request promotions of a tagged Go app release to "prod", fake managers can approve the request and everything should happen automagically after the approval with proper app tests.
```

with:

```markdown
- **Promotion**: Kargo (`gitops/apps/kargo.yaml`) promotes `event-generator` from a new "dev" environment to the existing "prod", gated by a real `AnalysisTemplate` health check (Argo Rollouts, `gitops/apps/argo-rollouts.yaml`) and a human's manual approval via Kargo's own dashboard/CLI (`kargo promote`). Evaluated and decided: no self-hosted Forgejo Git server or PR-based approval flow — Kargo's native manual approval satisfies the requirement without the extra infrastructure. See `helm/kargo-project` for the `Project`/`Warehouse`/`Stage` definitions.
```

- [ ] **Step 12: Commit and push the doc updates**

```bash
git add CLAUDE.md README.md
git commit -m "docs: mark sub-project 3b (Kargo promotion) complete"
git push origin main
```

## Self-Review Notes

- **Spec coverage:** environment topology (Task 4) ✓; Kargo native approval, no Forgejo (Task 5's `project.yaml`, Task 7's README update) ✓; per-environment-values-file promotion mechanics, no new branches (Task 5's `promotiontask.yaml`) ✓; real app-level verification via Argo Rollouts (Task 3, Task 5's `analysistemplate.yaml`) ✓; shared ClickHouse (Task 4 Step 3's values-dev.yaml comment) ✓; existing prod left unrenamed (Task 4 touches only `values.yaml`'s new `namespace` key, adds nothing that changes its deployed behavior) ✓; auto-provisioned credentials, no new manual tokens (Tasks 1-2, 6) ✓; full cold-rebuild + real promotion verification (Task 7) ✓; CLAUDE.md/README updates (Task 7) ✓; commenting standard applied throughout ✓.
- **Placeholder scan:** no TBD/TODO. The one explicitly-flagged uncertainty (`AnalysisTemplate`'s exact field shape) was resolved with verified ground truth from Argo Rollouts' own Go source before this plan was written (Task 5 Step 7's comment cites the exact file) — not left open. The `PromotionTask`'s Helm/Kargo delimiter collision is flagged explicitly as a real risk with an explicit verification step (Task 5 Step 8), not glossed over.
- **Type/name consistency:** Secret names `event-generator-repo`/`event-generator-image` and their `kargo.akuity.io/cred-type` labels used identically in Tasks 1-2 (creation) and referenced by Kargo's own credential-discovery convention in Task 5 (matched by `repoURL`, not by name — no literal cross-reference needed, but the `repoURL`/`imageRepoURL` values match exactly across `values.yaml` (Task 5) and both scripts (Tasks 1-2)). Application names `event-generator-dev`/`event-generator` used identically in Task 4 (creation), Task 5's `PromotionTask` vars (`appName`), and Task 7's verification. Values file paths `values-dev.yaml`/`values.yaml` consistent across Task 4 (creation) and Task 5's `values.yaml` (`devValuesFile`/`prodValuesFile`). Namespace `kind-lab` (the Kargo Project name) consistent across Tasks 1, 2, 5.
- **Post-draft fix caught during self-review:** the first draft of this plan assumed Kargo's Helm chart auto-generates an admin account the way every other operator installed in this repo does — it doesn't (confirmed against the chart's own `values.yaml`: `api.adminAccount.passwordHash`/`tokenSigningKey` are required unless `api.secret.name` points at an existing Secret). Added Task 3 Step 1 (`scripts/kargo-admin-up.sh`, using `htpasswd -bnBC 10 ""`, Kargo's own documented bcrypt-hash method) and wired it into `gitops/apps/kargo.yaml`'s `helm.values` and Task 6's `bootstrap.sh` changes; fixed Task 7's login step to capture the one-time-printed plaintext password from `cluster:up`'s own output rather than trying to read a plaintext value back out of Kubernetes (only the bcrypt hash is ever stored). Caught before dispatching any implementer — no wasted work, but flagging it here since it's exactly the kind of gap this self-review step exists to catch.
