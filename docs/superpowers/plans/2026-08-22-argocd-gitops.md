# ArgoCD GitOps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap ArgoCD in App-of-Apps mode and migrate cert-manager, the step-ca ClusterIssuer, the shared Gateway, dnsmasq, and the smoke-test app to be ArgoCD-managed, sourced from `https://github.com/tilraunastofan/kind-lab`. `task cluster:up` ends with `https://argocd.lab.test` reachable over a trusted cert.

**Architecture:** A minimal script-driven "layer 0" (kind, Cilium + Gateway API CRDs, unchanged) hands off to `scripts/argocd-up.sh`, which installs ArgoCD via Helm, wires a read-only SSH deploy key for the private GitHub repo, and applies a root App-of-Apps `Application`. The root app statically lists cert-manager, the gateway chart, smoke-test, and ArgoCD's own adopted release — all fully Git-sourced. The step-ca ClusterIssuer and dnsmasq need host-specific values (the Mac's hostname, the Gateway's dynamically-assigned LoadBalancer IP) that can't live in a static Git file; for those two, the *Helm chart* is Git-sourced but the *Application wrapper* carrying the computed values is rendered by `envsubst` and applied directly by script (same idempotent pattern `issuer-up.sh`/`dns-bootstrap.sh` already use today, one level indirected through ArgoCD instead of applying the raw resource).

**Tech Stack:** bash, `helm`, `kubectl`, ArgoCD (`argo/argo-cd` chart `10.4.0`, app `v3.5.1`), `gh` CLI (deploy key registration), `envsubst`, Gateway API, cert-manager (unchanged from sub-project 1).

**Spec:** `docs/superpowers/specs/2026-08-22-argocd-gitops-design.md`

## Global Constraints

- Cluster name: `kind-lab`. Lab domain: `lab.test`.
- GitHub repo: `git@github.com:tilraunastofan/kind-lab.git` (private, default branch `main`).
- ArgoCD Helm chart: `argo/argo-cd` version `10.4.0` from `https://argoproj.github.io/argo-helm`.
- Every script: `set -euo pipefail`, sources `scripts/lib.sh`, is safe to re-run (idempotent).
- Commit messages must follow Conventional Commits (`type: subject`).
- The Cilium hostname-isolation workaround (matching `hostname` on paired HTTP+HTTPS listeners, see `helm/smoke-test/gateway-listeners.yaml`'s existing comment and `cilium/cilium#44123`) must be preserved by the templated gateway chart.
- ArgoCD `Application` sync policy: `automated: {prune: true, selfHeal: true}` on every child app.
- Adoption, not reinstall: every migrated component's `Application` targets the same Helm release name/namespace the existing scripts already created, so ArgoCD reconciles the existing release rather than creating a duplicate.

---

## Task 1: `helm/cluster-issuer` becomes a Helm chart

**Files:**
- Create: `helm/cluster-issuer/Chart.yaml`
- Create: `helm/cluster-issuer/values.yaml`
- Create: `helm/cluster-issuer/templates/issuer.yaml`
- Delete: `helm/cluster-issuer/issuer.yaml.tmpl`

**Interfaces:**
- Consumes: nothing.
- Produces: a chart accepting `.Values.stepcaHost`, `.Values.stepcaPort`, `.Values.stepcaRootCaB64` — Task 6 and Task 8 pass these at apply time via an ArgoCD `Application`'s inline `spec.source.helm.values`.

- [ ] **Step 1: Write `helm/cluster-issuer/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-issuer
description: step-ca ACME ClusterIssuer for the kind-lab cluster
version: 0.1.0
```

- [ ] **Step 2: Write `helm/cluster-issuer/values.yaml`**

```yaml
stepcaHost: ""
stepcaPort: ""
stepcaRootCaB64: ""
```

- [ ] **Step 3: Write `helm/cluster-issuer/templates/issuer.yaml`** (same resource `issuer.yaml.tmpl` produced, templated with Helm syntax instead of `envsubst`)

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
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: lab-gateway
                namespace: lab-gateway
                kind: Gateway
                sectionName: http
```

- [ ] **Step 4: Delete the old template and verify the chart renders correctly**

```bash
rm helm/cluster-issuer/issuer.yaml.tmpl
helm template step-ca-acme helm/cluster-issuer \
  --set stepcaHost=jakobs-mac.local \
  --set stepcaPort=9443 \
  --set stepcaRootCaB64=dGVzdA==
```

Expected: renders a single `ClusterIssuer` manifest with `server: https://jakobs-mac.local:9443/acme/acme/directory` and `caBundle: dGVzdA==`, identical in shape to the old `envsubst`-rendered version.

- [ ] **Step 5: Commit**

```bash
git add helm/cluster-issuer
git commit -m "refactor: convert cluster-issuer to a Helm chart"
```

---

## Task 2: `helm/dns` becomes a Helm chart

**Files:**
- Create: `helm/dns/Chart.yaml`
- Create: `helm/dns/values.yaml`
- Create: `helm/dns/templates/dnsmasq.yaml`
- Delete: `helm/dns/dnsmasq.yaml.tmpl`

**Interfaces:**
- Consumes: nothing.
- Produces: a chart accepting `.Values.gatewayIP`, `.Values.configChecksum` — Task 9 passes these at apply time via an ArgoCD `Application`'s inline `spec.source.helm.values`.

- [ ] **Step 1: Write `helm/dns/Chart.yaml`**

```yaml
apiVersion: v2
name: dns
description: In-cluster dnsmasq resolving *.lab.test to the shared Gateway
version: 0.1.0
```

- [ ] **Step 2: Write `helm/dns/values.yaml`**

```yaml
gatewayIP: ""
configChecksum: ""
```

- [ ] **Step 3: Write `helm/dns/templates/dnsmasq.yaml`** (same resources `dnsmasq.yaml.tmpl` produced, templated with Helm syntax)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dns-utils
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dnsmasq-config
  namespace: dns-utils
data:
  dnsmasq.conf: |
    no-resolv
    address=/lab.test/{{ .Values.gatewayIP }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dnsmasq
  namespace: dns-utils
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dnsmasq
  template:
    metadata:
      labels:
        app: dnsmasq
      annotations:
        checksum/config: {{ .Values.configChecksum | quote }}
    spec:
      containers:
        - name: dnsmasq
          image: dockurr/dnsmasq:2.93
          args: ["-C", "/etc/dnsmasq.conf", "-k"]
          ports:
            - containerPort: 53
              protocol: UDP
            - containerPort: 53
              protocol: TCP
          volumeMounts:
            - name: config
              mountPath: /etc/dnsmasq.conf
              subPath: dnsmasq.conf
      volumes:
        - name: config
          configMap:
            name: dnsmasq-config
---
apiVersion: v1
kind: Service
metadata:
  name: dnsmasq
  namespace: dns-utils
spec:
  type: NodePort
  selector:
    app: dnsmasq
  ports:
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
      nodePort: 30053
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
      nodePort: 30053
```

- [ ] **Step 4: Delete the old template and verify the chart renders correctly**

```bash
rm helm/dns/dnsmasq.yaml.tmpl
helm template dns helm/dns --set gatewayIP=192.168.97.2 --set configChecksum=abc123
```

Expected: renders `Namespace`, `ConfigMap` (with `address=/lab.test/192.168.97.2`), `Deployment` (with `checksum/config: "abc123"` annotation), and `Service`, matching the old `envsubst` output.

- [ ] **Step 5: Commit**

```bash
git add helm/dns
git commit -m "refactor: convert dns to a Helm chart"
```

---

## Task 3: `helm/gateway` becomes a templated listeners chart

**Files:**
- Create: `helm/gateway/Chart.yaml`
- Modify: `helm/gateway/gateway.yaml` → replaced by `helm/gateway/values.yaml` + `helm/gateway/templates/gateway.yaml`
- Delete: `helm/smoke-test/gateway-listeners.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: a chart accepting `.Values.listeners` (list of `{name, hostname, certificateRef}`) — Task 5's `gitops/apps/gateway.yaml` Application supplies the list, currently one entry for `smoke` and one for `argocd` (added in this task).

- [ ] **Step 1: Write `helm/gateway/Chart.yaml`**

```yaml
apiVersion: v2
name: gateway
description: Shared lab-gateway Gateway with one HTTP+HTTPS listener pair per app
version: 0.1.0
```

- [ ] **Step 2: Write `helm/gateway/values.yaml`**

```yaml
listeners:
  - name: smoke
    hostname: smoke.lab.test
    certificateRef: smoke-tls
  - name: argocd
    hostname: argocd.lab.test
    certificateRef: argocd-tls
```

- [ ] **Step 3: Write `helm/gateway/templates/gateway.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lab-gateway
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: lab-gateway
spec:
  gatewayClassName: cilium
  listeners:
    {{- range .Values.listeners }}
    # Cilium 1.16.5 silently drops routing through a wildcard/hostname-less
    # http listener for any hostname claimed exactly by another listener on
    # this Gateway (upstream cilium/cilium#44123, unresolved). Every https
    # listener below is paired with an http listener on the *same* hostname
    # so cert-manager's ACME HTTP-01 solver HTTPRoute (which also targets
    # this hostname) keeps working. See helm/smoke-test's prior comment and
    # docs/superpowers/plans/2026-08-21-cluster-bootstrap.md Task 7.
    - name: http-{{ .name }}
      protocol: HTTP
      port: 80
      hostname: {{ .hostname }}
      allowedRoutes:
        namespaces:
          from: All
    - name: https-{{ .name }}
      protocol: HTTPS
      port: 443
      hostname: {{ .hostname }}
      tls:
        mode: Terminate
        certificateRefs:
          - name: {{ .certificateRef }}
      allowedRoutes:
        namespaces:
          from: All
    {{- end }}
```

- [ ] **Step 4: Delete the two files this chart replaces**

```bash
rm helm/gateway/gateway.yaml
rm helm/smoke-test/gateway-listeners.yaml
```

- [ ] **Step 5: Verify the chart renders both listener pairs correctly**

```bash
helm template lab-gateway helm/gateway
```

Expected: one `Namespace`, one `Gateway` with exactly 4 listeners: `http-smoke`/`https-smoke` (hostname `smoke.lab.test`, cert `smoke-tls`) and `http-argocd`/`https-argocd` (hostname `argocd.lab.test`, cert `argocd-tls`) — each HTTP/HTTPS pair sharing its hostname, matching the pattern in the deleted `gateway-listeners.yaml`.

- [ ] **Step 6: Commit**

```bash
git add helm/gateway helm/smoke-test/gateway-listeners.yaml
git commit -m "refactor: templated gateway chart, one listener pair per app"
```

---

## Task 4: `helm/argocd` — ArgoCD's own values and ingress

**Files:**
- Create: `helm/argocd/values.yaml`
- Create: `helm/argocd/extras/certificate.yaml`
- Create: `helm/argocd/extras/httproute.yaml`

**Interfaces:**
- Consumes: `lab-gateway`'s `https-argocd`/`http-argocd` listeners (Task 3), `step-ca-acme` `ClusterIssuer` (Task 1, existing).
- Produces: an `argocd-server` Service reachable at `argocd.lab.test` once cert-manager issues `argocd-tls` — consumed by Task 5's multi-source `argocd` `Application`.

- [ ] **Step 1: Write `helm/argocd/values.yaml`**

```yaml
fullnameOverride: argocd
configs:
  params:
    server.insecure: true
```

- [ ] **Step 2: Write `helm/argocd/extras/certificate.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-tls
  namespace: lab-gateway
spec:
  secretName: argocd-tls
  dnsNames:
    - argocd.lab.test
  issuerRef:
    name: step-ca-acme
    kind: ClusterIssuer
```

- [ ] **Step 3: Write `helm/argocd/extras/httproute.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  parentRefs:
    - name: lab-gateway
      namespace: lab-gateway
      sectionName: https-argocd
  hostnames:
    - argocd.lab.test
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
```

- [ ] **Step 4: Verify manifests are well-formed**

```bash
kubectl apply --dry-run=client -f helm/argocd/extras/certificate.yaml -f helm/argocd/extras/httproute.yaml
```

Expected: `certificate.cert-manager.io/argocd-tls (dry run)` and `httproute.gateway.networking.k8s.io/argocd (dry run)` printed with no errors (the cert-manager and Gateway API CRDs are already installed on the running `kind-lab` cluster from sub-project 1).

- [ ] **Step 5: Commit**

```bash
git add helm/argocd
git commit -m "feat: add ArgoCD values and ingress manifests"
```

---

## Task 5: Static `gitops/apps/*.yaml` Applications + root App-of-Apps

**Files:**
- Create: `gitops/root-app.yaml`
- Create: `gitops/apps/cert-manager.yaml`
- Create: `gitops/apps/gateway.yaml`
- Create: `gitops/apps/smoke-test.yaml`
- Create: `gitops/apps/argocd.yaml`

**Interfaces:**
- Consumes: nothing (pure Git content — these must be static since ArgoCD reads them from GitHub, not local disk).
- Produces: `root-app` — the one `Application` `scripts/argocd-up.sh` (Task 7) applies directly. Its `spec.source.path: gitops/apps` picks up the four files below by directory scan.

- [ ] **Step 1: Write `gitops/root-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: gitops/apps
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Write `gitops/apps/cert-manager.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://charts.jetstack.io
      chart: cert-manager
      targetRevision: v1.16.2
      helm:
        valueFiles:
          - $values/helm/cert-manager/values.yaml
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Write `gitops/apps/gateway.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: helm/gateway
  destination:
    server: https://kubernetes.default.svc
    namespace: lab-gateway
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Write `gitops/apps/smoke-test.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: smoke-test
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: helm/smoke-test
  destination:
    server: https://kubernetes.default.svc
    namespace: smoke-test
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 5: Write `gitops/apps/argocd.yaml`** (ArgoCD adopts its own Helm release, plus the extra Certificate/HTTPRoute from Task 4)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 10.4.0
      helm:
        valueFiles:
          - $values/helm/argocd/values.yaml
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      ref: values
    - repoURL: git@github.com:tilraunastofan/kind-lab.git
      targetRevision: main
      path: helm/argocd/extras
      directory:
        include: "*.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 6: Verify all five manifests are well-formed YAML**

```bash
for f in gitops/root-app.yaml gitops/apps/*.yaml; do
  kubectl apply --dry-run=client -f "$f" || echo "FAILED: $f"
done
```

Expected: five `application.argoproj.io/<name> (dry run)` lines (the `Application` CRD isn't installed yet at this point in the plan — if this dry-run errors with `no matches for kind "Application"`, that's expected and fine; re-run this same check after Task 7 installs ArgoCD to get a real validation). Note any YAML syntax errors now regardless.

- [ ] **Step 7: Commit**

```bash
git add gitops
git commit -m "feat: add App-of-Apps root and child Application manifests"
```

---

## Task 6: Templated Applications for host-specific values (cluster-issuer, dns)

**Files:**
- Create: `gitops/apps-templates/cluster-issuer.yaml.tmpl`
- Create: `gitops/apps-templates/dns.yaml.tmpl`

**Interfaces:**
- Consumes: `helm/cluster-issuer` (Task 1), `helm/dns` (Task 2).
- Produces: templates rendered by `scripts/issuer-up.sh` (Task 8) and `scripts/dns-bootstrap.sh` (Task 9) via `envsubst`, then `kubectl apply -f -`'d directly — **not** committed as rendered files, and deliberately kept out of `gitops/apps/` so `root-app`'s directory scan (Task 5) never tries to apply the unrendered `${VAR}` placeholders straight from Git.

- [ ] **Step 1: Write `gitops/apps-templates/cluster-issuer.yaml.tmpl`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-issuer
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: helm/cluster-issuer
    helm:
      values: |
        stepcaHost: "${STEPCA_HOST}"
        stepcaPort: "${STEPCA_PORT}"
        stepcaRootCaB64: "${STEPCA_ROOT_CA_B64}"
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Write `gitops/apps-templates/dns.yaml.tmpl`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dns
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:tilraunastofan/kind-lab.git
    targetRevision: main
    path: helm/dns
    helm:
      values: |
        gatewayIP: "${GATEWAY_IP}"
        configChecksum: "${CONFIG_CHECKSUM}"
  destination:
    server: https://kubernetes.default.svc
    namespace: dns-utils
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Verify substitution produces valid YAML**

```bash
STEPCA_HOST=jakobs-mac.local STEPCA_PORT=9443 STEPCA_ROOT_CA_B64=dGVzdA== \
  envsubst '${STEPCA_HOST} ${STEPCA_PORT} ${STEPCA_ROOT_CA_B64}' < gitops/apps-templates/cluster-issuer.yaml.tmpl \
  | kubectl apply --dry-run=client -f -
GATEWAY_IP=192.168.97.2 CONFIG_CHECKSUM=abc123 \
  envsubst '${GATEWAY_IP} ${CONFIG_CHECKSUM}' < gitops/apps-templates/dns.yaml.tmpl \
  | kubectl apply --dry-run=client -f -
```

Expected: same as Task 5 Step 6 — either a successful dry-run apply, or (if run before ArgoCD's CRDs exist) `no matches for kind "Application"`, which is expected at this point.

- [ ] **Step 4: Commit**

```bash
git add gitops/apps-templates
git commit -m "feat: add templated Applications for host-specific values"
```

---

## Task 7: `scripts/argocd-up.sh` — install ArgoCD, wire Git access, apply root app

**Files:**
- Create: `scripts/argocd-up.sh`

**Interfaces:**
- Consumes: `scripts/lib.sh`'s `log`/`warn`/`die`/`require_cmd`/`wait_for`, `CLUSTER_NAME`. Runs after `cilium-up.sh` (Cilium + Gateway CRDs already installed).
- Produces: the `argocd` namespace with ArgoCD running, a `kind-lab-repo-creds` Secret, and `root-app` applied and eventually `Synced`+`Healthy` — consumed by `bootstrap.sh` (Task 11) as the single hand-off point to GitOps.

- [ ] **Step 1: Write `scripts/argocd-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ARGOCD_CHART_VERSION="10.4.0"
DEPLOY_KEY_PATH="${HOME}/.ssh/kind-lab-argocd-deploy"
REPO_SSH_URL="git@github.com:tilraunastofan/kind-lab.git"
REPO_SLUG="tilraunastofan/kind-lab"

install_argocd() {
  log "installing ArgoCD ${ARGOCD_CHART_VERSION}"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --version "${ARGOCD_CHART_VERSION}" \
    --namespace argocd --create-namespace \
    --values "${SCRIPT_DIR}/../helm/argocd/values.yaml" \
    --kube-context "kind-${CLUSTER_NAME}" \
    --wait --timeout 5m
}

ensure_deploy_key() {
  if [ -f "${DEPLOY_KEY_PATH}" ]; then
    log "deploy key already exists at ${DEPLOY_KEY_PATH}, skipping generation"
    return 0
  fi
  log "generating deploy key at ${DEPLOY_KEY_PATH}"
  ssh-keygen -t ed25519 -N "" -C "kind-lab-argocd" -f "${DEPLOY_KEY_PATH}" >/dev/null
}

deploy_key_registered() {
  gh repo deploy-key list --repo "${REPO_SLUG}" --json title \
    --jq '.[] | select(.title == "kind-lab-argocd")' 2>/dev/null | grep -q .
}

register_deploy_key() {
  if deploy_key_registered; then
    log "deploy key already registered on ${REPO_SLUG}, skipping"
    return 0
  fi
  log "registering read-only deploy key on ${REPO_SLUG}"
  # gh deploy keys are read-only by default (write access is opt-in via -w/--allow-write)
  gh repo deploy-key add "${DEPLOY_KEY_PATH}.pub" --repo "${REPO_SLUG}" --title kind-lab-argocd
}

apply_repo_creds() {
  log "applying ArgoCD repo-creds secret for ${REPO_SSH_URL}"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kind-lab-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: ${REPO_SSH_URL}
  sshPrivateKey: |
$(sed 's/^/    /' "${DEPLOY_KEY_PATH}")
EOF
}

applications_healthy() {
  local not_healthy
  not_healthy=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' \
    | grep -vc '^Synced Healthy$' || true)
  [ "${not_healthy}" -eq 0 ]
}

main() {
  require_cmd helm kubectl ssh-keygen gh sed

  install_argocd
  ensure_deploy_key
  register_deploy_key
  apply_repo_creds

  log "applying root App-of-Apps"
  kubectl apply -f "${SCRIPT_DIR}/../gitops/root-app.yaml"

  wait_for "all ArgoCD Applications Synced and Healthy" 300 applications_healthy
  log "ArgoCD bootstrap complete"
}

main "$@"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/argocd-up.sh
```

- [ ] **Step 3: Run it against the live `kind-lab` cluster**

```bash
./scripts/argocd-up.sh
```

Expected: `ArgoCD bootstrap complete` printed at the end. If it times out on `applications_healthy`, run `kubectl -n argocd get applications` to see which app is stuck, and `kubectl -n argocd get application <name> -o yaml` for its `status.conditions` before proceeding — a `cert-manager` app stuck `OutOfSync`/`Degraded` most likely means the CRDs from sub-project 1's install aren't recognized as ArgoCD-owned yet; re-running `kubectl apply -f gitops/apps/cert-manager.yaml` after the initial sync usually clears a first-sync ownership hiccup.

- [ ] **Step 4: Verify the ArgoCD UI is reachable**

```bash
kubectl -n argocd get pods
kubectl -n argocd get applications
```

Expected: all `argocd-*` pods `Running`, and `root-app`, `cert-manager`, `gateway`, `smoke-test`, `argocd` Applications all `Synced`/`Healthy`.

- [ ] **Step 5: Commit**

```bash
git add scripts/argocd-up.sh
git commit -m "feat: add argocd-up.sh to install ArgoCD and apply the root app"
```

---

## Task 8: Rewrite `scripts/issuer-up.sh` to render+apply the `cluster-issuer` Application

**Files:**
- Modify: `scripts/issuer-up.sh`

**Interfaces:**
- Consumes: `gitops/apps-templates/cluster-issuer.yaml.tmpl` (Task 6).
- Produces: a `Synced`/`Healthy` `cluster-issuer` `Application` in the `argocd` namespace, which ArgoCD reconciles into the same `step-ca-acme` `ClusterIssuer` the old script applied directly.

- [ ] **Step 1: Rewrite `scripts/issuer-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

app_healthy() {
  local sync health
  sync=$(kubectl -n argocd get application cluster-issuer -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application cluster-issuer -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]
}

issuer_ready() {
  [ "$(kubectl get clusterissuer step-ca-acme -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

main() {
  require_cmd kubectl envsubst scutil openssl base64

  local host
  host="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
  export STEPCA_HOST="${host}"
  export STEPCA_PORT
  export STEPCA_ROOT_CA_B64
  STEPCA_ROOT_CA_B64=$(base64 < "${HOME}/.step/certs/root_ca.crt" | tr -d '\n')

  log "applying cluster-issuer Application (server https://${STEPCA_HOST}:${STEPCA_PORT}/acme/acme/directory)"
  envsubst '${STEPCA_HOST} ${STEPCA_PORT} ${STEPCA_ROOT_CA_B64}' \
    < "${SCRIPT_DIR}/../gitops/apps-templates/cluster-issuer.yaml.tmpl" | kubectl apply -f -

  wait_for "cluster-issuer Application Synced and Healthy" 90 app_healthy
  wait_for "ClusterIssuer step-ca-acme Ready" 60 issuer_ready
}

main "$@"
```

- [ ] **Step 2: Run it against the live cluster**

```bash
./scripts/issuer-up.sh
```

Expected: both `wait_for` lines print `: ready`, no errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/issuer-up.sh
git commit -m "refactor: issuer-up.sh applies the cluster-issuer Application via ArgoCD"
```

---

## Task 9: Rewrite `scripts/dns-bootstrap.sh` to render+apply the `dns` Application

**Files:**
- Modify: `scripts/dns-bootstrap.sh`

**Interfaces:**
- Consumes: `gitops/apps-templates/dns.yaml.tmpl` (Task 6).
- Produces: a `Synced`/`Healthy` `dns` `Application` in the `argocd` namespace, reconciling into the same `dnsmasq` Deployment/Service the old script applied directly.

- [ ] **Step 1: Rewrite `scripts/dns-bootstrap.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

RESOLVER_FILE="/etc/resolver/${LAB_DOMAIN}"

gateway_ip() {
  kubectl -n lab-gateway get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{end}'
}

node_ip() {
  kubectl get node "${CLUSTER_NAME}-control-plane" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

# config_checksum: see the original comment this script carried — stamped
# onto the dnsmasq Deployment's pod-template annotations so a changed
# Gateway IP forces a real rollout despite the subPath ConfigMap mount not
# being live-updated by the kubelet.
config_checksum() {
  local gw_ip="$1"
  printf 'no-resolv\naddress=/%s/%s\n' "${LAB_DOMAIN}" "${gw_ip}" | shasum -a 256 | awk '{print $1}'
}

resolver_up_to_date() {
  local node
  node=$(node_ip)
  [ -f "${RESOLVER_FILE}" ] && grep -q "nameserver ${node}" "${RESOLVER_FILE}" && grep -q "port 30053" "${RESOLVER_FILE}"
}

app_healthy() {
  local sync health
  sync=$(kubectl -n argocd get application dns -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application dns -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]
}

main() {
  require_cmd kubectl envsubst sudo shasum

  local gw_ip
  gw_ip=$(gateway_ip)
  [ -n "${gw_ip}" ] || die "lab-gateway has no LoadBalancer IP yet — run cluster-up/cilium-up/argocd-up first"

  local checksum
  checksum=$(config_checksum "${gw_ip}")

  log "applying dns Application (resolving *.${LAB_DOMAIN} -> ${gw_ip})"
  GATEWAY_IP="${gw_ip}" CONFIG_CHECKSUM="${checksum}" \
    envsubst '${GATEWAY_IP} ${CONFIG_CHECKSUM}' \
    < "${SCRIPT_DIR}/../gitops/apps-templates/dns.yaml.tmpl" | kubectl apply -f -

  wait_for "dns Application Synced and Healthy" 90 app_healthy
  kubectl -n dns-utils rollout status deployment/dnsmasq --timeout=60s

  if resolver_up_to_date; then
    log "${RESOLVER_FILE} already up to date, skipping"
    return 0
  fi

  local node
  node=$(node_ip)
  log "writing ${RESOLVER_FILE} (nameserver ${node}, port 30053) — requires sudo"
  sudo mkdir -p /etc/resolver
  printf 'nameserver %s\nport 30053\n' "${node}" | sudo tee "${RESOLVER_FILE}" >/dev/null
}

main "$@"
```

- [ ] **Step 2: Run it against the live cluster**

```bash
./scripts/dns-bootstrap.sh
```

Expected: `dns Application Synced and Healthy: ready`, dnsmasq rollout succeeds, resolver file reported up to date (already written by sub-project 1).

- [ ] **Step 3: Commit**

```bash
git add scripts/dns-bootstrap.sh
git commit -m "refactor: dns-bootstrap.sh applies the dns Application via ArgoCD"
```

---

## Task 10: Rewrite `scripts/smoke-test.sh` into the ArgoCD + HTTPS verification step

**Files:**
- Modify: `scripts/smoke-test.sh`
- Delete: `scripts/cert-manager-up.sh`

**Interfaces:**
- Consumes: `kubectl -n argocd get applications` (all child apps by now `Synced`/`Healthy`), `https://smoke.lab.test`, `https://argocd.lab.test`.
- Produces: the final `task cluster:up` / `task smoke:test` verification gate.

- [ ] **Step 1: Rewrite `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

applications_healthy() {
  local not_healthy
  not_healthy=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' \
    | grep -vc '^Synced Healthy$' || true)
  [ "${not_healthy}" -eq 0 ]
}

verify_https() {
  local host="$1"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' --cacert "${HOME}/.step/certs/root_ca.crt" --max-time 5 "https://${host}" 2>/dev/null || echo "000")
  [ "${status}" = "200" ]
}

main() {
  require_cmd kubectl curl

  wait_for "all ArgoCD Applications Synced and Healthy" 120 applications_healthy
  wait_for "https://argocd.${LAB_DOMAIN} returns 200" 90 verify_https "argocd.${LAB_DOMAIN}"
  wait_for "https://smoke.${LAB_DOMAIN} returns 200" 60 verify_https "smoke.${LAB_DOMAIN}"

  log "smoke test passed: ArgoCD healthy, https://argocd.${LAB_DOMAIN} and https://smoke.${LAB_DOMAIN} both served with a trusted cert"
}

main "$@"
```

- [ ] **Step 2: Delete `scripts/cert-manager-up.sh`** (cert-manager is now installed exclusively by the `cert-manager` ArgoCD Application from Task 5)

```bash
rm scripts/cert-manager-up.sh
```

- [ ] **Step 3: Run the new smoke test against the live cluster**

```bash
./scripts/smoke-test.sh
```

Expected: `smoke test passed: ArgoCD healthy, https://argocd.lab.test and https://smoke.lab.test both served with a trusted cert`.

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke-test.sh
git rm scripts/cert-manager-up.sh
git commit -m "feat: smoke-test.sh verifies ArgoCD health and argocd.lab.test HTTPS"
```

---

## Task 11: Update `bootstrap.sh` orchestration

**Files:**
- Modify: `bootstrap.sh`

**Interfaces:**
- Consumes: `scripts/cilium-up.sh` (unchanged), `scripts/argocd-up.sh` (Task 7), `scripts/issuer-up.sh` (Task 8), `scripts/dns-bootstrap.sh` (Task 9), `scripts/smoke-test.sh` (Task 10).
- Produces: the full `task cluster:up` entrypoint.

- [ ] **Step 1: Rewrite `bootstrap.sh`'s `main()`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

gateway_has_ip() {
  local ip
  ip=$(kubectl -n lab-gateway get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{end}' 2>/dev/null)
  [ -n "${ip}" ]
}

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

main "$@"
```

- [ ] **Step 2: Verify `require_cmd` additions are satisfied**

```bash
command -v ssh-keygen && command -v gh
```

Expected: both print a path (already true — `gh` was used to inspect the repo earlier in this session).

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: wire argocd-up.sh into bootstrap.sh, drop direct cert-manager/gateway/smoke steps"
```

---

## Task 12: Update `scripts/cluster-status.sh` and `scripts/cluster-down.sh`

**Files:**
- Modify: `scripts/cluster-status.sh`
- Modify: `scripts/cluster-down.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `task cluster:status` reporting ArgoCD Application health; `task cluster:down` unaffected in behavior (kind cluster deletion already tears down everything, including ArgoCD).

- [ ] **Step 1: Add an ArgoCD section to `scripts/cluster-status.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  require_cmd kubectl
  echo "--- Nodes ---"
  kubectl get nodes
  echo "--- Cilium ---"
  kubectl -n kube-system get pods -l k8s-app=cilium
  echo "--- GatewayClass ---"
  kubectl get gatewayclass
  echo "--- ArgoCD ---"
  kubectl -n argocd get pods
  echo "--- ArgoCD Applications ---"
  kubectl -n argocd get applications
  echo "--- cert-manager ---"
  kubectl -n cert-manager get pods
  echo "--- lab-gateway ---"
  kubectl -n lab-gateway get gateway,svc
  echo "--- dnsmasq ---"
  kubectl -n dns-utils get pods,svc
  echo "--- ClusterIssuer ---"
  kubectl get clusterissuer step-ca-acme
}

main "$@"
```

- [ ] **Step 2: `scripts/cluster-down.sh` needs no functional change** — confirm by reading it: `kind delete cluster --name kind-lab` removes every namespace including `argocd`, so no ArgoCD-specific teardown step is needed. Leave the file as-is.

- [ ] **Step 3: Run the updated status script against the live cluster**

```bash
./scripts/cluster-status.sh
```

Expected: prints the new `--- ArgoCD ---` and `--- ArgoCD Applications ---` sections with `Running` pods and `Synced`/`Healthy` apps, alongside the existing sections.

- [ ] **Step 4: Commit**

```bash
git add scripts/cluster-status.sh
git commit -m "feat: cluster-status.sh reports ArgoCD pod and Application health"
```

---

## Task 13: Update `README.md`

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: accurate user-facing docs for the new `task cluster:up` behavior.

- [ ] **Step 1: Update the "Cluster GitOps" bullet and Task targets / Troubleshooting sections**

Edit `README.md`:
- Under `#### Cluster GitOps`, change the ArgoCD bullet from a forward-looking statement to reflect it's implemented: mention `https://argocd.lab.test` as the reachable UI, and that `gitops/apps/` in this repo is the source of truth.
- Under "Task targets", update `task cluster:up`'s description to mention ArgoCD: `bootstrap the full lab cluster (step-ca, cloud-provider-kind, kind, Cilium, ArgoCD/GitOps, cert-manager, DNS, smoke test)`.
- Under "Troubleshooting", add a bullet: if `scripts/argocd-up.sh` times out waiting for Applications to become `Healthy`, check `kubectl -n argocd get applications` for the stuck one and `kubectl -n argocd get application <name> -o yaml`'s `status.conditions` — the most common first-bootstrap cause is ArgoCD's initial sync racing an existing (script-created) Helm release's ownership metadata; re-applying that one `gitops/apps/<name>.yaml` after the first sync usually resolves it.
- Add a note that the GitOps source repo is `https://github.com/tilraunastofan/kind-lab` and that a git push there is what triggers ArgoCD's auto-sync going forward (not `task cluster:up`, which only re-applies the root app pointer).

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document ArgoCD GitOps bootstrap and troubleshooting"
```

---

## Task 14: Full end-to-end verification

**Files:** none (verification only).

**Interfaces:** none.

- [ ] **Step 1: Push this branch's work to the GitHub remote** (ArgoCD pulls from `main` — the root app and all child Applications must be reachable there before a fresh bootstrap can succeed)

```bash
git push origin main
```

- [ ] **Step 2: Full teardown/rebuild**

```bash
task cluster:down
task cluster:up
```

Expected: completes without manual intervention (aside from the documented first-run `sudo` steps, if this is a genuinely fresh workstation state) and ends with `kind-lab bootstrap complete`.

- [ ] **Step 3: Verify ArgoCD UI over trusted HTTPS**

```bash
curl -v https://argocd.lab.test 2>&1 | grep -iE "issuer|subject|HTTP/"
```

Expected: `issuer:` line shows the step-ca intermediate CA, `HTTP/1.1 200` (or `HTTP/2 200`).

- [ ] **Step 4: Verify the smoke-test regression check**

```bash
curl -v https://smoke.lab.test 2>&1 | grep -iE "issuer|subject|HTTP/"
```

Expected: same trusted-cert pattern, `200` — proves the refactored gateway chart still serves a pre-existing hostname correctly.

- [ ] **Step 5: Verify all Applications are Synced and Healthy**

```bash
kubectl -n argocd get applications
```

Expected: `root-app`, `cert-manager`, `gateway`, `smoke-test`, `argocd`, `cluster-issuer`, `dns` — all `Synced`/`Healthy`.

- [ ] **Step 6: Update `CLAUDE.md`'s "Project status" section** to record sub-project 2 as complete, following the same style as the existing sub-project 1 paragraph, then commit.

```bash
git add CLAUDE.md
git commit -m "docs: mark sub-project 2 (ArgoCD GitOps) complete"
```
