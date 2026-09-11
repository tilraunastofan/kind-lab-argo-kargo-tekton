# Simplified lab (kind-lab-argo-kargo-tekton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `kind-lab-argo-kargo-tekton` as a Cilium-free sibling of `~/kind-lab`, keeping ArgoCD GitOps, the event-generator/Clickhouse demo app, Datadog observability, Kargo promotion, and Tekton + Pipelines-as-Code — with Tekton and ArgoCD as the headline demo features — mirrored to a self-hosted Forgejo instance for Tekton's webhook trigger.

**Architecture:** Port the most complete branch of `~/kind-lab` (`worktree-forgejo-tekton`) into this repo, then (a) replace Cilium (CNI + Gateway API ingress) with kind's bundled `kindnet` CNI + `ingress-nginx`/plain `Ingress` resources, (b) rename all `kind-lab`-specific identifiers (cluster name, domain, GHCR path, repo URLs, Forgejo slug) to avoid clobbering the original lab, and (c) set up a Forgejo pull-mirror of this GitHub repo so Pipelines-as-Code has a webhook source.

**Tech Stack:** kind, kubectl, Helm, ArgoCD (App-of-Apps), ingress-nginx, cert-manager + step-ca (ACME HTTP-01), Kargo, Tekton Pipelines + Pipelines-as-Code, Datadog Operator, Forgejo (Gitea-compatible API), bash + Taskfile.

**Spec:** `docs/superpowers/specs/2026-09-11-simplified-lab-design.md`

## Global Constraints

- Source tree to port from: `~/kind-lab/.claude/worktrees/forgejo-tekton` at commit `64c7589` (the `worktree-forgejo-tekton` branch).
- New kind cluster name: `tekton-lab` (was `kind-lab`).
- New local domain: `*.tekton-lab.test` (was `*.lab.test`).
- New GHCR image path: `ghcr.io/tilraunastofan/kind-lab-argo-kargo-tekton/event-generator` (was `ghcr.io/tilraunastofan/kind-lab/event-generator`).
- New GitHub repo (already exists, empty): `https://github.com/tilraunastofan/kind-lab-argo-kargo-tekton` — all ArgoCD `Application.spec.source.repoURL` values must point at `git@github.com:tilraunastofan/kind-lab-argo-kargo-tekton.git`.
- New Forgejo repo slug for the PAC mirror: `<forgejo-username>/kind-lab-argo-kargo-tekton` (owner looked up dynamically via the Forgejo API using `FORGEJO_TOKEN`, same pattern the source scripts already use — never hardcode the owner).
- Ingress class for every app: `nginx`. ACME solver: `http01.ingress` (not `gatewayHTTPRoute`).
- `ClusterIssuer` name stays `step-ca-acme` (unchanged).
- This is a learning-lab repo for the user's team: every new or rewritten file gets more generous explanatory (WHY, not WHAT) comments than default — call this out per-task below where it applies.
- Every file ported unchanged (no functional edit in this plan) must still be copied byte-for-byte — do not "clean up" or refactor content outside a task's stated scope.

---

### Task 1: Port the baseline tree and apply repo-wide renaming

**Files:**
- Create: this repo's full tree, copied from the source (see step 1)
- Modify (via scripted rename, in place after copy): `scripts/lib.sh`, `cluster/kind-config.yaml` (rename only, CNI removal is Task 2), every `gitops/apps/*.yaml`, every `gitops/apps-templates/*.tmpl`, `gitops/root-app.yaml`, `scripts/build-and-push.sh`, `scripts/registry-secret-up.sh`, `scripts/forgejo-repo-up.sh`, `scripts/pac-forgejo-secret-up.sh`, `scripts/pac-config-up.sh`, `scripts/pac-lan-forward-up.sh`, `scripts/dns-bootstrap.sh`, `scripts/cluster-status.sh`, `bootstrap.sh`, `Taskfile.yaml`, `helm/event-generator/values.yaml`, `helm/event-generator/values-dev.yaml`, `helm/*/extras*/httproute.yaml`, `helm/*/extras*/certificate.yaml`, `helm/smoke-test/app.yaml`, `helm/smoke-test/certificate.yaml`, `helm/pipelines-as-code-config/templates/*.yaml`
- Skip (do not port): `.git/`, `.claude/worktrees/`, `.claude/scheduled_tasks.lock`, any `.DS_Store`

**Interfaces:**
- Produces: the full repo tree at `~/kind-lab-argo-kargo-tekton`, with `tekton-lab`/`tekton-lab.test`/`kind-lab-argo-kargo-tekton` substituted everywhere except historical docs (Task 4 handles those). Later tasks assume this tree exists and is already renamed.

- [ ] **Step 1: Copy the source tree**

Run from `~/kind-lab-argo-kargo-tekton` (this repo's root — it currently only has `README.md`, `.git/`, and `docs/superpowers/specs/2026-09-11-simplified-lab-design.md`, so don't overwrite that spec file):

```bash
SRC=~/kind-lab/.claude/worktrees/forgejo-tekton
DST=~/kind-lab-argo-kargo-tekton

for d in bootstrap.sh CLAUDE.md KARGO-METHODS.md cluster demo-apps gitops helm scripts Taskfile.yaml vendor .tekton .superpowers docs/superpowers/plans; do
  rsync -a --exclude='.DS_Store' "${SRC}/${d}" "${DST}/$(dirname "${d}")/" 2>/dev/null || rsync -a --exclude='.DS_Store' "${SRC}/${d}" "${DST}/"
done
# README.md and docs/superpowers/specs already exist in this repo (README
# from the initial commit, one spec from this project's own brainstorming
# session) — copy the source README as a starting point for Task 4 to
# rewrite, and copy any OTHER source spec files (not ours) for historical
# reference.
cp "${SRC}/README.md" "${DST}/README.md.source-for-task4"
rsync -a --exclude='.DS_Store' "${SRC}/docs/superpowers/specs/" "${DST}/docs/superpowers/specs/"
```

- [ ] **Step 2: Verify the copy landed**

Run: `cd ~/kind-lab-argo-kargo-tekton && find . -maxdepth 2 -not -path './.git*' | sort`
Expected: the same top-level layout `~/kind-lab/.claude/worktrees/forgejo-tekton` has (`bootstrap.sh`, `cluster/`, `demo-apps/`, `gitops/`, `helm/`, `scripts/`, `Taskfile.yaml`, `vendor/`, `.tekton/`, plus this repo's own `docs/superpowers/specs/2026-09-11-simplified-lab-design.md` and `README.md.source-for-task4`).

- [ ] **Step 3: Rename cluster name and domain in `scripts/lib.sh`**

```bash
cd ~/kind-lab-argo-kargo-tekton
sed -i '' 's/CLUSTER_NAME="kind-lab"/CLUSTER_NAME="tekton-lab"/' scripts/lib.sh
sed -i '' 's/LAB_DOMAIN="lab\.test"/LAB_DOMAIN="tekton-lab.test"/' scripts/lib.sh
```

- [ ] **Step 4: Repo-wide mechanical rename — hostnames, GitHub repo URL, GHCR path**

Every other file only ever refers to the old cluster name/domain/GHCR path/GitHub repo as literal strings (never derived from `lib.sh`'s variables — confirmed by the earlier `grep -rl` audit), so a repo-wide sed pass is safe and won't touch `scripts/lib.sh` (already handled in Step 3) or the historical docs under `docs/superpowers/plans/` (deliberately excluded — Task 4 adds a disclaimer there instead of rewriting history):

```bash
cd ~/kind-lab-argo-kargo-tekton
FILES=$(grep -rlE '\.lab\.test|kind-lab/event-generator|github\.com/tilraunastofan/kind-lab\.git|FORGEJO_REPO_NAME="kind-lab"' \
  --include='*.sh' --include='*.yaml' --include='*.yml' --include='*.tmpl' \
  bootstrap.sh cluster demo-apps gitops helm scripts Taskfile.yaml .tekton 2>/dev/null)

for f in $FILES; do
  sed -i '' \
    -e 's/\.lab\.test/\.tekton-lab.test/g' \
    -e 's#kind-lab/event-generator#kind-lab-argo-kargo-tekton/event-generator#g' \
    -e 's#github\.com/tilraunastofan/kind-lab\.git#github.com/tilraunastofan/kind-lab-argo-kargo-tekton.git#g' \
    -e 's/FORGEJO_REPO_NAME="kind-lab"/FORGEJO_REPO_NAME="kind-lab-argo-kargo-tekton"/' \
    "$f"
done
```

- [ ] **Step 5: Verify the rename**

Run:
```bash
cd ~/kind-lab-argo-kargo-tekton
grep -rE '\.lab\.test|kind-lab/event-generator|tilraunastofan/kind-lab\.git' \
  bootstrap.sh cluster demo-apps gitops helm scripts Taskfile.yaml .tekton 2>/dev/null
grep -n 'CLUSTER_NAME\|LAB_DOMAIN' scripts/lib.sh
```
Expected: the first command prints nothing (no leftover old references outside `docs/superpowers/plans/`); the second prints `CLUSTER_NAME="tekton-lab"` and `LAB_DOMAIN="tekton-lab.test"`.

- [ ] **Step 6: Commit**

```bash
cd ~/kind-lab-argo-kargo-tekton
git add -A
git commit -m "$(cat <<'EOF'
feat: port kind-lab's forgejo-tekton branch and rename to tekton-lab

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Replace Cilium (CNI + Gateway API) with kindnet + ingress-nginx

**Files:**
- Modify: `cluster/kind-config.yaml`, `helm/cluster-issuer/templates/issuer.yaml`, `bootstrap.sh`, `scripts/dns-bootstrap.sh`, `scripts/pac-lan-forward-up.sh`, `scripts/cluster-status.sh`, `Taskfile.yaml`
- Create: `gitops/apps/ingress-nginx.yaml`, `helm/argocd/extras/ingress.yaml`, `helm/event-generator/extras/ingress.yaml`, `helm/event-generator/extras-dev/ingress.yaml`, `helm/headlamp/extras/ingress.yaml`, `helm/pipelines-as-code-config/templates/ingress.yaml`
- Delete: `helm/cilium/`, `helm/gateway/`, `scripts/cilium-up.sh`, `gitops/apps/gateway.yaml`, `helm/argocd/extras/httproute.yaml`, `helm/argocd/extras/certificate.yaml`, `helm/event-generator/extras/httproute.yaml`, `helm/event-generator/extras/certificate.yaml`, `helm/event-generator/extras-dev/httproute.yaml`, `helm/event-generator/extras-dev/certificate.yaml`, `helm/headlamp/extras/httproute.yaml`, `helm/headlamp/extras/certificate.yaml`, `helm/pipelines-as-code-config/templates/httproute.yaml`, `helm/pipelines-as-code-config/templates/certificate.yaml`, `helm/smoke-test/certificate.yaml`
- Modify: `helm/smoke-test/app.yaml` (replace its embedded `HTTPRoute` with an `Ingress`)

**Interfaces:**
- Consumes: the renamed tree from Task 1 (`tekton-lab.test` hostnames, `step-ca-acme` ClusterIssuer name).
- Produces: every app reachable over HTTPS via `ingress-nginx` + plain `Ingress` objects, with cert-manager's ingress-shim auto-creating each app's `Certificate` from the `cert-manager.io/cluster-issuer` annotation (no hand-authored `Certificate` manifests going forward). Task 6 (end-to-end verification) relies on `kubectl -n ingress-nginx get svc ingress-nginx-controller` existing with a `LoadBalancer` IP.

- [ ] **Step 1: Drop the custom CNI in `cluster/kind-config.yaml`**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: tekton-lab
networking:
  # No disableDefaultCNI here (unlike the Cilium-based kind-lab): kind's
  # bundled kindnet CNI handles pod networking on its own. Cilium's real
  # job in this repo was never "better pod networking" — it was doubling
  # as the Gateway API ingress implementation (see gitops/apps/ingress-nginx.yaml
  # and helm/cluster-issuer for its plain-Ingress replacement). Dropping
  # it here removes an entire pre-ArgoCD bootstrap step and a CNI-version-
  # vs-Gateway-API-CRD-schema pinning problem this lab doesn't need to
  # demo Tekton/ArgoCD/Kargo.
  podSubnet: "10.244.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

- [ ] **Step 2: Delete the Cilium chart, script, and Gateway chart/Application**

```bash
cd ~/kind-lab-argo-kargo-tekton
rm -rf helm/cilium helm/gateway
rm -f scripts/cilium-up.sh gitops/apps/gateway.yaml
```

- [ ] **Step 3: Add the `ingress-nginx` ArgoCD Application**

Create `gitops/apps/ingress-nginx.yaml`:

```yaml
# gitops/apps/ingress-nginx.yaml
#
# Installs ingress-nginx (https://kubernetes.github.io/ingress-nginx) —
# this lab's replacement for Cilium's Gateway API implementation. Plain
# Ingress resources instead of Gateway API's Gateway/HTTPRoute objects,
# on purpose: it fully decouples the CNI (kindnet, cluster/kind-config.yaml)
# from the ingress/TLS layer again, and it's the more widely-known
# building block for a lab whose point is demoing Tekton/ArgoCD/Kargo,
# not ingress internals.
#
# Early sync-wave ("-2"), same tier as clickhouse-operator/tekton-pipelines
# (gitops/apps/clickhouse-operator.yaml, gitops/apps/tekton-pipelines.yaml):
# cert-manager's ClusterIssuer (helm/cluster-issuer) needs a working
# `nginx` IngressClass to solve ACME HTTP-01 challenges through, and every
# app below depends on the controller Pod being up to get a LoadBalancer
# IP at all — bootstrap.sh's own wait_for (Step 5 below) blocks on it.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ingress-nginx
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: https://kubernetes.github.io/ingress-nginx
    chart: ingress-nginx
    targetRevision: 4.11.3
    helm:
      values: |
        controller:
          service:
            type: LoadBalancer
  destination:
    server: https://kubernetes.default.svc
    namespace: ingress-nginx
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

- [ ] **Step 4: Rewrite the ACME solver in `helm/cluster-issuer/templates/issuer.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-ca-acme
spec:
  acme:
    server: https://{{ .Values.stepcaHost }}:{{ .Values.stepcaPort }}/acme/acme/directory
    caBundle: {{ .Values.stepcaRootCaB64 }}
    privateKeySecretRef:
      name: step-ca-acme-account-key
    solvers:
      # http01.ingress (not gatewayHTTPRoute): cert-manager creates a
      # temporary solver Ingress in the challenged app's own namespace,
      # using this ingressClassName, instead of a Gateway HTTPRoute
      # against a shared Gateway. Simpler and avoids the old Cilium
      # Gateway API hostname-isolation bug workaround entirely (see the
      # deleted helm/gateway/templates/gateway.yaml's comment for what
      # that used to require).
      - http01:
          ingress:
            ingressClassName: nginx
```

- [ ] **Step 5: Replace each app's HTTPRoute+Certificate with a plain Ingress**

Create `helm/argocd/extras/ingress.yaml` (delete `helm/argocd/extras/httproute.yaml` and `helm/argocd/extras/certificate.yaml`):

```yaml
# helm/argocd/extras/ingress.yaml
#
# Plain Kubernetes Ingress — replaces the old Gateway API HTTPRoute +
# hand-authored Certificate pair. The cert-manager.io/cluster-issuer
# annotation is cert-manager's "ingress-shim": it auto-creates a
# Certificate matching this Ingress's spec.tls block (dnsNames +
# secretName) on its own, so no separate Certificate manifest is needed
# per app any more — a plain Ingress's TLS Secret lives in the same
# namespace as the Ingress itself, unlike a Gateway's, which had to live
# in the Gateway's own namespace (lab-gateway) regardless of which app it
# belonged to.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: step-ca-acme
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - argocd.tekton-lab.test
      secretName: argocd-tls
  rules:
    - host: argocd.tekton-lab.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

Create `helm/event-generator/extras/ingress.yaml` (delete the matching `httproute.yaml`/`certificate.yaml` in that same `extras/` dir):

```yaml
# helm/event-generator/extras/ingress.yaml
#
# Same shape as helm/argocd/extras/ingress.yaml — see that file's comment
# for why there's no separate Certificate manifest any more.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: event-generator
  namespace: demo-app
  annotations:
    cert-manager.io/cluster-issuer: step-ca-acme
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - event-generator.tekton-lab.test
      secretName: event-generator-tls
  rules:
    - host: event-generator.tekton-lab.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: event-generator
                port:
                  number: 80
```

Create `helm/event-generator/extras-dev/ingress.yaml` (delete the matching `httproute.yaml`/`certificate.yaml`; keep `clickhouse-secret.yaml` untouched, it's unrelated to networking):

```yaml
# helm/event-generator/extras-dev/ingress.yaml
#
# dev's counterpart to helm/event-generator/extras/ingress.yaml — same
# ACME ClusterIssuer, different namespace/hostname/Secret so it doesn't
# collide with prod's.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: event-generator
  namespace: demo-app-dev
  annotations:
    cert-manager.io/cluster-issuer: step-ca-acme
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - event-generator-dev.tekton-lab.test
      secretName: event-generator-dev-tls
  rules:
    - host: event-generator-dev.tekton-lab.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: event-generator
                port:
                  number: 80
```

Create `helm/headlamp/extras/ingress.yaml` (delete the matching `httproute.yaml`/`certificate.yaml`; keep `helm/headlamp/extras/rbac.yaml` untouched):

```yaml
# helm/headlamp/extras/ingress.yaml
#
# Same shape as helm/argocd/extras/ingress.yaml.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp
  namespace: headlamp
  annotations:
    cert-manager.io/cluster-issuer: step-ca-acme
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - headlamp.tekton-lab.test
      secretName: headlamp-tls
  rules:
    - host: headlamp.tekton-lab.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: headlamp
                port:
                  number: 80
```

Create `helm/pipelines-as-code-config/templates/ingress.yaml` (delete the matching `httproute.yaml`/`certificate.yaml` in that same `templates/` dir; keep `repository.yaml` untouched):

```yaml
# helm/pipelines-as-code-config/templates/ingress.yaml
#
# Routes pipelines-as-code.tekton-lab.test to PAC's controller Service
# (installed by vendor/pipelines-as-code/release.yaml) — port 8080, the
# Service's own "http-listener" port. Same ingress-shim pattern as every
# other app in this repo (see helm/argocd/extras/ingress.yaml).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pipelines-as-code
  namespace: pipelines-as-code
  annotations:
    cert-manager.io/cluster-issuer: step-ca-acme
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - pipelines-as-code.tekton-lab.test
      secretName: pipelines-as-code-tls
  rules:
    - host: pipelines-as-code.tekton-lab.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pipelines-as-code-controller
                port:
                  number: 8080
```

- [ ] **Step 6: Convert `helm/smoke-test/app.yaml`'s embedded HTTPRoute to an Ingress, delete its separate Certificate**

```bash
rm -f helm/smoke-test/certificate.yaml
```

Replace the `HTTPRoute` document at the bottom of `helm/smoke-test/app.yaml` with:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: smoke-nginx
  namespace: smoke-test
  annotations:
    cert-manager.io/cluster-issuer: step-ca-acme
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - smoke.tekton-lab.test
      secretName: smoke-tls
  rules:
    - host: smoke.tekton-lab.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: smoke-nginx
                port:
                  number: 80
```

(the `Namespace`/`Deployment`/`Service` documents above it in that same file are untouched.)

- [ ] **Step 7: Update `bootstrap.sh`'s sequencing**

Remove the `"${SCRIPT_DIR}/cilium-up.sh"` line entirely (kindnet needs no install step). Replace the `gateway_has_ip`/`wait_for "lab-gateway has a LoadBalancer IP"` pair with:

```bash
ingress_has_ip() {
  local ip
  ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "${ip}" ]
}
```
and
```bash
  wait_for "ingress-nginx-controller has a LoadBalancer IP" 60 ingress_has_ip
```

Update the final log line from `"kind-lab bootstrap complete"` to `"tekton-lab bootstrap complete"`.

- [ ] **Step 8: Update `scripts/dns-bootstrap.sh`'s IP lookup**

Replace the `gateway_ip()` function:

```bash
ingress_ip() {
  kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}
```

and update every call site that referenced `gateway_ip` to call `ingress_ip` instead (the rest of the script — `node_ip`, `config_checksum`, `resolver_up_to_date`, `app_healthy`, `main` — is unchanged apart from that rename).

- [ ] **Step 9: Update `scripts/pac-lan-forward-up.sh`'s IP lookup**

Replace `current_gateway_ip()`:

```bash
# current_ingress_ip: ingress-nginx's live cloud-provider-kind
# LoadBalancer IP (can change across cluster restarts). Only one
# LoadBalancer Service exists in the ingress-nginx namespace, so no
# name-filtering awk trick is needed here (the old lab-gateway namespace
# could, in principle, hold more than one).
current_ingress_ip() {
  kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}
```

Update every call site (`main()`'s `gateway_ip="$(current_gateway_ip)"` etc.) and log/comment text referring to "the Gateway" to refer to "ingress-nginx" instead. `PAC_HOSTNAME` should already read `pipelines-as-code.tekton-lab.test` from Task 1's rename.

- [ ] **Step 10: Update `scripts/cluster-status.sh`**

Replace the `--- Cilium ---` / `--- GatewayClass ---` / `--- lab-gateway ---` sections with:

```bash
  echo "--- ingress-nginx ---"
  kubectl -n ingress-nginx get pods,svc,ingressclass
```

(keep the `--- Nodes ---`, `--- ArgoCD ---`, `--- ArgoCD Applications ---`, `--- cert-manager ---`, `--- dnsmasq ---`, `--- ClusterIssuer ---` sections as-is.)

- [ ] **Step 11: Update `Taskfile.yaml`'s `cluster:up` description**

```yaml
  cluster:up:
    desc: Bootstrap the full tekton-lab cluster (step-ca, cloud-provider-kind, kind, ingress-nginx, cert-manager, DNS, smoke test)
    cmds:
      - ./bootstrap.sh
```

- [ ] **Step 12: Verify no Cilium/Gateway API references remain (outside historical docs)**

```bash
cd ~/kind-lab-argo-kargo-tekton
grep -rEl 'cilium|Cilium|gatewayHTTPRoute|HTTPRoute|gateway\.networking\.k8s\.io|lab-gateway' \
  bootstrap.sh cluster demo-apps gitops helm scripts Taskfile.yaml .tekton 2>/dev/null
```
Expected: no output.

- [ ] **Step 13: Render every changed chart with `helm template` to catch YAML errors**

```bash
cd ~/kind-lab-argo-kargo-tekton
for chart in helm/argocd helm/event-generator helm/headlamp helm/pipelines-as-code-config helm/cluster-issuer; do
  echo "--- ${chart} ---"
  helm template "${chart}" >/dev/null
done
kubectl apply --dry-run=client -f gitops/apps/ingress-nginx.yaml -f helm/smoke-test/app.yaml
```
Expected: every `helm template` invocation exits 0 with no error output; the `kubectl apply --dry-run=client` prints `created (dry run)` for each resource.

- [ ] **Step 14: Commit**

```bash
cd ~/kind-lab-argo-kargo-tekton
git add -A
git commit -m "$(cat <<'EOF'
feat: replace Cilium CNI+Gateway API with kindnet+ingress-nginx

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Rework the Forgejo scripts for the pull-mirror model and new repo slug

**Files:**
- Modify: `scripts/forgejo-repo-up.sh`, `helm/pipelines-as-code-config/templates/repository.yaml`
- No change needed: `scripts/pac-forgejo-secret-up.sh` (already namespace/secret-only, renamed correctly by Task 1's sed pass — verify in Step 3 below), `scripts/pac-config-up.sh`, `scripts/pac-ca-trust-up.sh`, `scripts/pac-forgejo-trust-up.sh` (Pi-side trust/DNS scripts — unaffected by the mirror-vs-manual-push distinction)

**Interfaces:**
- Consumes: `FORGEJO_TOKEN` env var (already exported), `pac-forgejo-creds` Secret (created by `pac-forgejo-secret-up.sh`).
- Produces: `scripts/forgejo-repo-up.sh` that (a) ensures a Forgejo repo exists as a **pull mirror** of this GitHub repo (rather than an empty repo + a `forgejo` git remote to push to by hand) and (b) registers the PAC webhook against it — both idempotent, safe to run from `bootstrap.sh`.

- [ ] **Step 1: Rewrite `scripts/forgejo-repo-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_URL="https://git.local"
FORGEJO_REPO_NAME="kind-lab-argo-kargo-tekton"
GITHUB_CLONE_URL="https://github.com/tilraunastofan/kind-lab-argo-kargo-tekton.git"

# Ensures a kind-lab-argo-kargo-tekton repo exists on the user's
# self-hosted Forgejo instance (git.local, on the same LAN) as a PULL
# MIRROR of this GitHub repo — Forgejo periodically re-pulls main on its
# own after a `git push` to GitHub, no `git push forgejo main` step to
# remember (unlike the original kind-lab, which used a manually-pushed
# second remote — this repo's Forgejo copy is purely a webhook-delivery
# source for Tekton Pipelines-as-Code, so a passive mirror is simpler and
# just as effective). A webhook is then registered against the mirror
# repo, same as before, pointing at PAC's controller.
#
# Mirroring a *private* GitHub repo needs read credentials Forgejo can use
# when it pulls — GITHUB_MIRROR_TOKEN (a GitHub PAT scoped to `repo` read,
# or `gh auth token` for a quick one) supplies that. Requires FORGEJO_TOKEN
# (a Forgejo personal access token with Repository:Write/Issue:Write
# scopes) for talking to Forgejo's own API, same as always.
#
# Uses curl directly against Forgejo's REST API (Gitea-API-compatible v1)
# rather than a dedicated CLI — same reasoning as before.

forgejo_api() {
  curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

main() {
  require_cmd kubectl curl jq

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first"
  fi
  if [ -z "${GITHUB_MIRROR_TOKEN:-}" ]; then
    die "GITHUB_MIRROR_TOKEN is not set — export a GitHub token with read access to this repo (e.g. \$(gh auth token)) first"
  fi

  log "looking up Forgejo username for the token"
  local owner
  owner="$(forgejo_api "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
  [ -n "${owner}" ] && [ "${owner}" != "null" ] || die "could not determine Forgejo username — check FORGEJO_TOKEN and ${FORGEJO_URL} reachability"

  # Checked via the API, not the web UI path, for the same reason the
  # original script documents: a private repo's web page 404s under
  # token auth even when it exists, which would make this non-idempotent.
  if forgejo_api "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}" -o /dev/null 2>/dev/null; then
    log "mirror repo ${owner}/${FORGEJO_REPO_NAME} already exists on ${FORGEJO_URL}, skipping creation"
  else
    log "creating ${owner}/${FORGEJO_REPO_NAME} on ${FORGEJO_URL} as a pull mirror of ${GITHUB_CLONE_URL}"
    forgejo_api -X POST "${FORGEJO_URL}/api/v1/repos/migrate" \
      -d "{\"clone_addr\": \"${GITHUB_CLONE_URL}\", \"auth_token\": \"${GITHUB_MIRROR_TOKEN}\", \"repo_name\": \"${FORGEJO_REPO_NAME}\", \"repo_owner\": \"${owner}\", \"mirror\": true, \"mirror_interval\": \"10m0s\", \"private\": true}" >/dev/null
  fi

  log "reading webhook shared secret from pac-forgejo-creds"
  local webhook_secret
  webhook_secret="$(kubectl -n pipelines-as-code get secret pac-forgejo-creds \
    -o jsonpath='{.data.webhook\.secret}' | base64 -d)"
  [ -n "${webhook_secret}" ] || die "pac-forgejo-creds has no webhook.secret key — run pac-forgejo-secret-up.sh first"

  log "checking for an existing webhook on ${owner}/${FORGEJO_REPO_NAME}"
  local existing_hook_id
  existing_hook_id="$(forgejo_api "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}/hooks" \
    | jq -r '.[] | select(.config.url == "https://pipelines-as-code.tekton-lab.test") | .id' | head -1)"

  local hook_payload
  hook_payload=$(cat <<EOF
{
  "type": "forgejo",
  "active": true,
  "config": {
    "url": "https://pipelines-as-code.tekton-lab.test",
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

  log "mirror + webhook ready: ${FORGEJO_URL}/${owner}/${FORGEJO_REPO_NAME} (pulls main from GitHub automatically; no manual push needed)"
}

main "$@"
```

- [ ] **Step 2: Update `helm/pipelines-as-code-config/templates/repository.yaml`**

Change `metadata.name` from `kind-lab` to `kind-lab-argo-kargo-tekton`, and `spec.url` from
`"https://git.local/{{ .Values.forgejoOwner }}/kind-lab"` to
`"https://git.local/{{ .Values.forgejoOwner }}/kind-lab-argo-kargo-tekton"`.

- [ ] **Step 3: Verify Task 1's rename already covered the other PAC scripts correctly**

```bash
cd ~/kind-lab-argo-kargo-tekton
grep -n 'FORGEJO_REPO_NAME\|kind-lab' scripts/pac-forgejo-secret-up.sh scripts/pac-config-up.sh scripts/pac-ca-trust-up.sh scripts/pac-forgejo-trust-up.sh
```
Expected: no bare `kind-lab` (only `kind-lab-argo-kargo-tekton`, or no match at all — these four scripts don't hardcode the repo name themselves, only the two files touched in Steps 1-2 do).

- [ ] **Step 4: Commit**

```bash
cd ~/kind-lab-argo-kargo-tekton
git add -A
git commit -m "$(cat <<'EOF'
feat: switch Forgejo repo to a GitHub pull mirror, rename PAC repo slug

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Rewrite README/CLAUDE.md/KARGO-METHODS.md and flag historical docs

**Files:**
- Modify: `README.md` (replace with an edited version of the ported `README.md.source-for-task4`, then delete that temp file), `CLAUDE.md`, `KARGO-METHODS.md`
- Create: `docs/superpowers/plans/README.md` (one-paragraph disclaimer for the ported historical plans)

**Interfaces:**
- Consumes: `README.md.source-for-task4` (Task 1's copy of the original lab's README), the original `CLAUDE.md`/`KARGO-METHODS.md` ported in Task 1.
- Produces: docs that describe *this* repo's architecture (Tekton + ArgoCD headlined, Cilium absent) while pointing at the ported historical plans/specs as background reading.

- [ ] **Step 1: Rewrite `README.md`**

Start from `README.md.source-for-task4` and apply these edits, then `rm README.md.source-for-task4`:

- Title/intro: change the opening line to note this is the simplified, Tekton/ArgoCD-focused sibling of the original `kind-lab`, with a link-free one-line mention that Cilium/Gateway API networking was intentionally dropped in favor of `ingress-nginx` (point readers at `docs/superpowers/specs/2026-09-11-simplified-lab-design.md` for the full rationale).
- In the "Cluster" bullet, replace `- ingress is Cilium's Gateway API implementation; cert-manager solves ACME HTTP-01 challenges through it, so traffic is real HTTPS end-to-end` with:
  `- ingress is ingress-nginx (a plain Kubernetes Ingress controller); cert-manager solves ACME HTTP-01 challenges through it via cert-manager's ingress-shim, so traffic is real HTTPS end-to-end`
- In "Cluster GitOps", replace every `argocd.lab.test` / `smoke-test.lab.test`-style hostname with the `*.tekton-lab.test` equivalent (Task 1's sed pass already fixed these — verify, don't re-edit if already correct).
- Re-order the tech-stack bullets so **Tekton Pipelines + Pipelines-as-Code** appears directly after "Cluster GitOps" (promoted from its current spot near the bottom, matching the user's ask to headline Tekton alongside ArgoCD), and expand its one-liner to summarize what's demoed: a real `git push` to the Forgejo mirror triggering a PAC-discovered pipeline via webhook.
- Update "GitOps workflow"'s repo URL from `https://github.com/tilraunastofan/kind-lab` to `https://github.com/tilraunastofan/kind-lab-argo-kargo-tekton`.
- In "Troubleshooting", drop the two Cilium/Gateway-API-specific entries (the `storedVersions` CRD race and the `cilium-gateway` mention) — they no longer apply; keep the `cloud-provider-kind`/clickhouse-operator entries, updating any `lab-gateway`/`lab.test` mentions in them to `ingress-nginx`/`tekton-lab.test`.
- Update "Task targets" and "Prerequisites" sections' cluster-name/domain mentions per Task 1's rename (verify, don't re-edit if already correct).

- [ ] **Step 2: Update `CLAUDE.md`**

In the "Project status" section:
- Sub-project 1's paragraph: replace "Cilium as CNI and Gateway API implementation" with "kind's bundled kindnet CNI and ingress-nginx for Ingress-based TLS termination", and update `smoke.lab.test` → `smoke.tekton-lab.test`.
- Sub-project 2 and later paragraphs: update every `*.lab.test` hostname to `*.tekton-lab.test` (verify Task 1's sed pass caught these).
- Sub-project 5's paragraph: update `pipelines-as-code.lab.test` → `pipelines-as-code.tekton-lab.test`, and its mention of "the Gateway's LoadBalancer IP" → "ingress-nginx's LoadBalancer IP".
- Add one closing sentence to the Project status section: "This repo (`kind-lab-argo-kargo-tekton`) is a simplified, Tekton/ArgoCD-focused fork of the original `kind-lab` — Cilium's CNI and Gateway API roles were replaced by kind's bundled `kindnet` and `ingress-nginx` respectively; see `docs/superpowers/specs/2026-09-11-simplified-lab-design.md` for the full rationale, and `docs/superpowers/plans/README.md` for how the ported historical plans below relate to this repo."
- In "Intent" and "Open decisions": update the "TLS"/"Ingress controller" bullets to describe ingress-nginx instead of Cilium's Gateway API implementation (the underlying `helm/cluster-issuer`/`helm/*/extras/ingress.yaml` files are now the source of truth, not an "open decision" — mark that bullet resolved).

- [ ] **Step 3: Update `KARGO-METHODS.md`**

Read the file and update any `*.lab.test` hostnames, the GHCR image path, and any mention of the Gateway/Cilium (if the dashboard-access instructions reference a hostname reachable only via the old Gateway, point them at the equivalent `ingress-nginx`-fronted hostname instead — if Kargo's dashboard is still port-forward-only, no change needed there).

- [ ] **Step 4: Add a disclaimer for the ported historical plans**

Create `docs/superpowers/plans/README.md`:

```markdown
# Historical plans

The plan files in this directory (except this one) were ported verbatim
from `~/kind-lab`'s `worktree-forgejo-tekton` branch — they document how
each sub-project of the *original* `kind-lab` was actually built and
verified, including its Cilium-based CNI/Gateway API setup. They are kept
here as learning material (what problems came up, how they were
diagnosed and fixed), not as a description of this repo's current state.

For what actually changed in this simplified fork — Cilium removed,
ingress-nginx in its place, renamed cluster/domain/GHCR path, Forgejo
mirror instead of a manually-pushed second remote — see
`docs/superpowers/specs/2026-09-11-simplified-lab-design.md` and
`docs/superpowers/plans/2026-09-11-simplified-lab.md` (this plan) instead.
```

- [ ] **Step 5: Commit**

```bash
cd ~/kind-lab-argo-kargo-tekton
git add -A
git commit -m "$(cat <<'EOF'
docs: rewrite README/CLAUDE.md/KARGO-METHODS.md for the simplified lab

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Push to GitHub and stand up the Forgejo mirror

**Files:** none (operational task — running scripts/commands, no repo file changes expected beyond what's already committed)

**Interfaces:**
- Consumes: `origin` remote (already `https://github.com/tilraunastofan/kind-lab-argo-kargo-tekton.git`), `FORGEJO_TOKEN` (already in env), a GitHub read token for `GITHUB_MIRROR_TOKEN` (`gh auth token`), `scripts/forgejo-repo-up.sh` and `scripts/pac-forgejo-secret-up.sh` from Task 3.
- Produces: this repo's `main` branch pushed to GitHub; a Forgejo repo at `<owner>/kind-lab-argo-kargo-tekton` mirroring it.

- [ ] **Step 1: Push to GitHub**

```bash
cd ~/kind-lab-argo-kargo-tekton
git push -u origin main
```
Expected: push succeeds (this repo's `origin` already points at the existing empty GitHub repo per this session's earlier `git remote -v` check).

- [ ] **Step 2: Confirm Forgejo reachability and `FORGEJO_TOKEN`**

```bash
curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" https://git.local/api/v1/user | jq .login
```
Expected: prints the Forgejo username. If `git.local` isn't reachable directly from this Mac, run the same check over SSH: `ssh cm4.local 'curl -sf -H "Authorization: token '"${FORGEJO_TOKEN}"'" https://git.local/api/v1/user' | jq .login` (Forgejo runs on the Pi itself, so `localhost`/its own hostname is always reachable from there).

- [ ] **Step 3: Create the pac-forgejo-creds prerequisite is deferred to Task 6**

(`scripts/pac-forgejo-secret-up.sh` needs a live cluster to create a Kubernetes Secret in — this step is a no-op placeholder marker only in the sense that it's intentionally *not* run yet; the real invocation happens as part of Task 6's `bootstrap.sh` run. Nothing to execute here.)

- [ ] **Step 4: Manually verify the mirror creation call once, standalone**

Since `scripts/forgejo-repo-up.sh` (Task 3) also reads `pac-forgejo-creds` from the cluster (not yet up), don't run the full script yet. Instead, directly verify the Forgejo migrate API call works with real credentials, so any auth/API problem surfaces now rather than mid-`bootstrap.sh` in Task 6:

```bash
FORGEJO_URL="https://git.local"
OWNER="$(curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
GITHUB_MIRROR_TOKEN="$(gh auth token)"

curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" -H "Content-Type: application/json" \
  -X POST "${FORGEJO_URL}/api/v1/repos/migrate" \
  -d "{\"clone_addr\": \"https://github.com/tilraunastofan/kind-lab-argo-kargo-tekton.git\", \"auth_token\": \"${GITHUB_MIRROR_TOKEN}\", \"repo_name\": \"kind-lab-argo-kargo-tekton\", \"repo_owner\": \"${OWNER}\", \"mirror\": true, \"mirror_interval\": \"10m0s\", \"private\": true}" | jq '.full_name, .mirror'
```
Expected: prints `"<owner>/kind-lab-argo-kargo-tekton"` and `true`.

- [ ] **Step 5: Verify the mirror actually pulled `main`**

```bash
curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" \
  "https://git.local/api/v1/repos/${OWNER}/kind-lab-argo-kargo-tekton/commits?limit=1" | jq '.[0].sha'
```
Expected: matches `git -C ~/kind-lab-argo-kargo-tekton rev-parse HEAD` (allow a minute or two — Forgejo's own mirror sync can take a short moment after the initial migrate call, unrelated to the `mirror_interval` used for later re-syncs).

No commit for this task (no repo files change).

---

### Task 6: Full end-to-end cluster verification

**Files:** none (operational/verification task)

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: a running `tekton-lab` kind cluster with every ArgoCD Application `Synced`/`Healthy`, every app reachable over trusted HTTPS at its `*.tekton-lab.test` hostname, a real Tekton PAC pipeline run triggered by a genuine `git push`, and a spot-checked Kargo promotion.

- [ ] **Step 1: Tear down the existing `~/kind-lab` cluster**

```bash
cd ~/kind-lab
task cluster:down
```
Expected: exits 0; `kind get clusters` no longer lists `kind-lab`.

- [ ] **Step 2: Export required env vars and bootstrap the new cluster**

```bash
cd ~/kind-lab-argo-kargo-tekton
export DATADOG_API_KEY=... # same value used by ~/kind-lab
export GHCR_PULL_TOKEN=...  # read:packages-scoped GitHub token
export FORGEJO_TOKEN=...    # already in env per this session
export GITHUB_MIRROR_TOKEN="$(gh auth token)"
task cluster:up
```
Expected: completes without a `die`; if it stops for the one-time `sudo` steps (step-ca root trust, `cloud-provider-kind` LaunchDaemon — same as the original lab's documented first-run behavior), run the printed command and re-run `task cluster:up`.

- [ ] **Step 3: Verify cluster health**

```bash
task cluster:status
```
Expected: all ArgoCD Applications `Synced`/`Healthy`, `ingress-nginx` pods `Running` with a `LoadBalancer` IP on `ingress-nginx-controller`, `cert-manager` pods `Running`, `ClusterIssuer step-ca-acme` present.

- [ ] **Step 4: Verify every app over trusted HTTPS**

```bash
for host in argocd headlamp event-generator smoke pipelines-as-code; do
  echo "--- ${host}.tekton-lab.test ---"
  curl -sS -o /dev/null -w '%{http_code}\n' "https://${host}.tekton-lab.test"
done
```
Expected: each prints a `2xx`/`3xx` HTTP status with no TLS trust error (the local step-ca root is already trusted by this Mac's system keychain).

- [ ] **Step 5: Run `scripts/pac-lan-forward-up.sh` and confirm the Pi can reach the cluster**

```bash
./scripts/pac-lan-forward-up.sh
```
Expected: completes with "pac-lan-forward ready" and a successful `curl --resolve` smoke test through the forwarder.

- [ ] **Step 6: Trigger a real Tekton PAC pipeline run**

```bash
cd ~/kind-lab-argo-kargo-tekton
git commit --allow-empty -m "chore: trigger PAC pipeline for end-to-end verification"
git push origin main
```
Wait for Forgejo's mirror to pull (or trigger it immediately via the Forgejo API's mirror-sync endpoint: `curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" -X POST "https://git.local/api/v1/repos/${OWNER}/kind-lab-argo-kargo-tekton/mirror-sync"`), then:

```bash
kubectl -n pipelines-as-code get pipelinerun --sort-by=.metadata.creationTimestamp
```
Expected: a new `PipelineRun` named `tekton-lab-pac-poc-...` (or whatever `generateName` `.tekton/pipelinerun.yaml` still uses post-rename) reaches `Succeeded`; `kubectl -n pipelines-as-code logs -l tekton.dev/pipelineRun=<name>` shows `"pac says hi from ..."`.

- [ ] **Step 7: Spot-check Kargo promotion**

Follow `KARGO-METHODS.md`'s documented access method to reach the Kargo dashboard/CLI, confirm the `kind-lab` Project's `dev` Stage is healthy, and (if a new event-generator build is available) exercise a promotion to `prod` per that doc's existing instructions — no new steps beyond what `KARGO-METHODS.md` (Task 4) already documents.

- [ ] **Step 8: Record verification results**

Append a short "Project status" paragraph to `CLAUDE.md` (same style as the existing sub-project paragraphs) summarizing this end-to-end verification (cluster name, what passed, any bugs hit and fixed along the way — following the existing documentation convention in that file), then commit:

```bash
cd ~/kind-lab-argo-kargo-tekton
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: record end-to-end verification of the simplified tekton-lab cluster

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Self-review notes

- **Spec coverage:** networking swap (Task 2), naming (Tasks 1 & 3), kept-as-is content (Task 1's copy, untouched by later tasks), comments (baked into every new/rewritten file across Tasks 2-4), Forgejo mirror (Tasks 3 & 5), testing (Task 6) — all spec sections have a corresponding task.
- **Placeholder scan:** every step above gives exact file content, exact commands, or an exact instruction with concrete search/replace text — no "TBD"/"handle appropriately" language.
- **Type/name consistency:** `ingress-nginx-controller` Service name, `ingress-nginx` namespace, `step-ca-acme` ClusterIssuer name, and `tekton-lab.test`/`tekton-lab` are used identically across every task that references them.
