# Simplified lab: kind-lab-argo-kargo-tekton — design

## Goal

Produce a simpler sibling of `~/kind-lab` that drops all Cilium-specific
networking (CNI + Gateway API ingress) while keeping every other feature —
ArgoCD GitOps, the event-generator/Clickhouse demo app, Datadog observability,
Kargo promotion, and the Tekton + Pipelines-as-Code CI proof-of-concept — so
Tekton, ArgoCD and Kargo can be demoed without the Cilium/Gateway API
complexity riding along. This repo is a private GitHub repo
(`tilraunastofan/kind-lab-argo-kargo-tekton`), mirrored to a self-hosted
Forgejo instance (`https://git.local`, reachable via SSH at `cm4.local`) so
Tekton Pipelines-as-Code has a push source to react to. As a learning-lab
repo for the user's team, code should carry more generous explanatory
comments than a typical production repo.

## Source of truth

Ported from `~/kind-lab`'s `worktree-forgejo-tekton` git worktree/branch —
the most complete lineage, verified end-to-end through: cluster bootstrap →
ArgoCD App-of-Apps → event-generator/Clickhouse demo app → Datadog
observability → Kargo promotion (dev→prod) → Forgejo + Tekton
Pipelines-as-Code. That tree becomes the baseline; this spec describes what
changes relative to it.

## Naming (to avoid clobbering the existing kind-lab cluster if both exist on
the same Mac at once)

| Concept | Old (`kind-lab`) | New (this repo) |
|---|---|---|
| kind cluster name | `kind-lab` | `tekton-lab` |
| local domain | `*.lab.test` | `*.tekton-lab.test` |
| GHCR image path | `ghcr.io/tilraunastofan/kind-lab/event-generator` | `ghcr.io/tilraunastofan/kind-lab-argo-kargo-tekton/event-generator` |
| GitHub repo | `tilraunastofan/kind-lab` | `tilraunastofan/kind-lab-argo-kargo-tekton` |
| Forgejo repo slug (PAC) | `jakob/kind-lab` | `jakob/kind-lab-argo-kargo-tekton` |

## Networking: what's removed, what replaces it

Cilium currently serves two independent roles: CNI (pod networking) and the
Gateway API implementation cert-manager uses for ACME HTTP-01 + TLS
termination for every app. Both go away together, replaced by simpler,
more standard building blocks:

- **CNI**: `cluster/kind-config.yaml` drops `disableDefaultCNI: true` — kind's
  bundled `kindnet` CNI handles pod networking. No CNI Helm chart, no
  `scripts/cilium-up.sh`, no Gateway API CRD install step, no
  Cilium-version-vs-CRD-schema pinning concerns.
- **Ingress/TLS**: a static `gitops/apps/ingress-nginx.yaml` ArgoCD
  Application installs the upstream `ingress-nginx` chart, same pattern as
  any other ArgoCD-managed app (no special pre-ArgoCD bootstrap step
  needed, unlike Cilium which had to exist before the cluster had pod
  networking at all).
- **`helm/gateway`** (the hand-rolled shared-Gateway chart) is deleted.
  Each app that used to render a `Gateway` listener pair now gets a plain
  `Ingress` resource instead.
- **`helm/cluster-issuer`**: the `ClusterIssuer`'s ACME solver switches from
  `http01.gatewayHTTPRoute` (pointed at `lab-gateway`) to
  `http01.ingress` with `ingressClassName: nginx`.
- **Per-app `extras/httproute.yaml` → `extras/ingress.yaml`**: `helm/argocd`,
  `helm/event-generator`, `helm/headlamp`, and `helm/smoke-test` each get a
  plain `Ingress` (host + TLS secretName, same certificateRef/secretName
  convention as today) instead of an `HTTPRoute` against the shared Gateway.
  `helm/pipelines-as-code-config` gets the same treatment for
  `pipelines-as-code.tekton-lab.test`.
- **`scripts/dns-bootstrap.sh`**: looks up the `ingress-nginx-controller`
  Service's LoadBalancer IP (still via `cloud-provider-kind`, unaffected by
  the CNI/Gateway swap) instead of `lab-gateway`'s.
- **`scripts/pac-lan-forward-up.sh`** (Pi→Mac webhook delivery forwarder):
  same idea, forwards to the ingress-nginx controller's IP:443 instead of
  the Gateway's. The underlying LAN-reachability bug this script works
  around (`cloud-provider-kind`'s LB bound to loopback) is orthogonal to
  Cilium and still applies.
- Kargo's own dashboard/API has no Gateway/Ingress exposure today (accessed
  via port-forward per `KARGO-METHODS.md`) — untouched by this change.

Everything else that currently depends on "the cluster has HTTPS ingress
with a trusted cert" (ArgoCD UI, event-generator, Headlamp, smoke-test,
pipelines-as-code UI) keeps working, just via Ingress instead of Gateway
API — same end-user behavior (`https://<app>.tekton-lab.test`, trusted
cert from the local step-ca), different plumbing underneath.

## Kept unchanged (content-wise; only renamed per the table above)

- ArgoCD App-of-Apps GitOps (`gitops/root-app.yaml`, `gitops/apps/`,
  `gitops/apps-templates/`)
- cert-manager + step-ca intermediate CA (`helm/cert-manager`,
  `scripts/issuer-up.sh`, `scripts/stepca-bootstrap.sh`)
- `demo-apps/event-generator` + Clickhouse (`helm/clickhouse*`,
  `scripts/build-and-push.sh`, `scripts/registry-secret-up.sh`)
- Datadog Operator/Agent (`helm/datadog-agent`,
  `scripts/datadog-secret-up.sh`)
- Kargo promotion (`helm/kargo-project`, `scripts/kargo-*-up.sh`,
  `KARGO-METHODS.md`)
- Tekton Pipelines + Pipelines-as-Code (`vendor/tekton-pipelines`,
  `vendor/pipelines-as-code`, `helm/pipelines-as-code-config`,
  `.tekton/pipelinerun.yaml`, `scripts/pac-*-up.sh`,
  `scripts/forgejo-repo-up.sh`) — including the four environmental bug
  fixes already discovered upstream (LAN forwarding, step-ca trust into
  Forgejo, `ALLOWED_HOST_LIST`, PAC controller/watcher CA trust), which
  remain necessary regardless of the CNI/ingress swap.
- Headlamp (`helm/headlamp`)

## Forgejo mirror setup

Create `jakob/kind-lab-argo-kargo-tekton` on `git.local` as a **pull
mirror** of `github.com/tilraunastofan/kind-lab-argo-kargo-tekton` (per
user preference — Forgejo periodically syncs on its own; no manual
dual-push step). Configured via the Forgejo API using `FORGEJO_TOKEN`
(already in env), from the Mac if `git.local` is reachable directly, or
via `ssh cm4.local` otherwise. `scripts/forgejo-repo-up.sh` and
`scripts/pac-forgejo-secret-up.sh` get their hardcoded repo-owner/name
updated to the new slug; the PAC webhook is registered against the mirror
the same way the original lab does it.

## Comments / documentation style

Per explicit user request (this is a learning lab for their team), code
in this repo carries more generous explanatory comments than default —
still focused on non-obvious *why* (a workaround, an ordering constraint,
a gotcha discovered the hard way), but with a lower bar for "worth
explaining" than a typical production repo. `README.md`, `CLAUDE.md`, and
`KARGO-METHODS.md` are ported and updated to describe the simplified
architecture, with Tekton/PAC given top billing alongside ArgoCD as the
headline demo features (Cilium/Gateway API not mentioned except perhaps
a one-line note on why it's absent, for anyone comparing against the
original `kind-lab`).

## Testing / verification

Full end-to-end verification, matching the bar the original sub-projects
were held to:

1. `task cluster:down` against the existing `~/kind-lab` cluster first,
   freeing ports 80/443, the `cloud-provider-kind` LaunchDaemon, and the
   `/etc/resolver` DNS override it holds (user has approved this).
2. `task cluster:up` on the new repo from a cold state: kind cluster →
   ArgoCD → ingress-nginx → cert-manager/step-ca → DNS → demo app/Clickhouse
   → Datadog → Kargo → Tekton/PAC.
3. Confirm every app reachable over trusted HTTPS at its
   `*.tekton-lab.test` hostname (ArgoCD, event-generator, Headlamp,
   smoke-test, pipelines-as-code).
4. Confirm the Forgejo pull-mirror actually pulls this repo's `main` after
   a GitHub push.
5. Trigger a real Tekton PAC pipeline run via a real `git push` (not a
   synthetic webhook redelivery — the original bugs were only caught this
   way) and confirm it reaches `Succeeded` with status posted back to the
   Forgejo mirror commit.
6. Spot-check Kargo promotion (dev→prod PromotionTask) still works against
   the renamed event-generator image path.

## Out of scope

- No new features beyond what already exists in `~/kind-lab`'s
  `worktree-forgejo-tekton` branch — this is a subtraction (Cilium) plus a
  substitution (ingress-nginx) plus renaming, not new functionality.
- Not attempting to keep the two clusters (`kind-lab` and `tekton-lab`)
  running simultaneously long-term — the naming split just avoids
  accidental collision during the cutover/verification window.
