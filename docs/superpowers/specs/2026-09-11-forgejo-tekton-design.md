# Sub-project: Forgejo + Tekton (Pipelines-as-Code) — Design

**Status:** Approved for planning
**Depends on:** Sub-project 2 (ArgoCD GitOps), complete — this is installed the
same way every other in-cluster component is. Independent of sub-project 3b
(Kargo promotion), which already exists as a separate in-progress worktree.

## Goal

Prove out Tekton Pipelines + [Pipelines-as-Code](https://pipelinesascode.com/docs/providers/forgejo/)
(PAC) triggered by the user's self-hosted Forgejo instance (`https://git.local`,
running on a Raspberry Pi on the same LAN). A push to a Forgejo-hosted mirror
of this repo should trigger a Tekton `PipelineRun` in-cluster, end to end.
This is a proof-of-concept for the mechanics, not a replacement for the
existing GitHub Actions CI (`.github/workflows/ci.yml`), which is explicitly
out of scope and untouched.

## Scope decisions made during brainstorming

- **Relationship to existing CI**: GitHub Actions stays as-is. This is a
  second, independent pipeline proving Tekton/PAC mechanics — not a
  migration.
- **Relationship to Kargo promotion (sub-project 3b)**: unrelated. That
  spec already explicitly decided **against** Forgejo for promotion
  approval ("Kargo's native approval satisfies the requirement without a
  second Git server or PR workflow" — see
  `docs/superpowers/specs/2026-08-28-kargo-promotion-design.md`). This
  sub-project does not reopen that decision; Forgejo here exists purely to
  drive Tekton, not promotion approvals.
- **Repo used**: `kind-lab` itself is mirrored to Forgejo (not a throwaway
  demo repo), via a second git remote. GitHub stays the source of truth;
  push to the `forgejo` remote is a manual, deliberate action (`git push
  forgejo main`), not an automatic/scheduled mirror — this keeps a
  proof-of-concept from silently becoming a second always-on CI system
  that can drift from GitHub.
- **Install scope**: Tekton Pipelines + Pipelines-as-Code only. No Tekton
  Triggers, no Tekton Dashboard — PAC bundles its own webhook
  controller/listener and needs neither.
- **Pipeline content**: minimal/trivial (e.g. clone + `echo` + `ls`), not a
  port of `ci.yml`'s lint/test/build-push jobs. The goal is proving
  push → webhook → `PipelineRun` → pod runs, not duplicating existing CI.
- **Webhook exposure**: a new hostname on the existing shared Gateway
  (`pipelines-as-code.lab.test`), following the exact pattern
  `argocd.lab.test`/`event-generator.lab.test` already use — one entry
  appended to `helm/gateway/values.yaml`'s `listeners` list, cert issued
  automatically by the existing cert-manager ACME `ClusterIssuer`. No new
  ingress mechanism introduced.
- **Network assumption**: `git.local` is already reachable and resolving
  from the Mac, same as `lab.test` hostnames. Taken as given per the
  user — if PAC's controller (running as a cluster pod) turns out unable
  to resolve/reach `git.local` (e.g. because `.local` normally resolves via
  mDNS/Bonjour, which doesn't reach into the kind cluster's Docker network
  the way the existing dnsmasq solves it for `*.lab.test`), that is a
  concrete risk to catch during implementation, not something to
  pre-solve here.

## Components

```
gitops/
  apps/
    tekton-pipelines.yaml       # Tekton Pipelines core, namespace tekton-pipelines
    pipelines-as-code.yaml      # PAC controller/webhook/watcher, namespace pipelines-as-code
scripts/
  pac-forgejo-secret-up.sh      # creates the PAC webhook + Forgejo token Secret
  forgejo-repo-up.sh            # creates/ensures the kind-lab mirror repo on Forgejo via API
helm/
  gateway/
    values.yaml                 # +1 listener: pipelines-as-code.lab.test
.tekton/
  pipelinerun.yaml               # PAC-discovered minimal PipelineRun definition
```

### Tekton Pipelines + Pipelines-as-Code install

Two new `gitops/apps/` ArgoCD Applications, same shape as every other
operator in this repo (`clickhouse-operator.yaml`, `datadog-operator.yaml`):
official upstream release YAML (Tekton's install manifests aren't a Helm
chart — ArgoCD can source raw YAML manifests from a URL the same way it
sources a chart), pinned to a specific released version, `namespace:
tekton-pipelines` and `namespace: pipelines-as-code` respectively.
`pipelines-as-code.yaml` needs an ArgoCD sync-wave after
`tekton-pipelines.yaml` (Tekton's CRDs must exist first) — the same
CRD-before-CR ordering already solved for `clickhouse-operator`/`clickhouse`
and `datadog-operator`/`datadog-agent`.

### Gateway exposure

`helm/gateway/values.yaml` gets one more listener entry:

```yaml
- name: pipelines-as-code
  hostname: pipelines-as-code.lab.test
  certificateRef: pipelines-as-code-tls
```

A `Certificate`/`HTTPRoute` pair for PAC's controller Service, following
`helm/event-generator/extras/certificate.yaml`'s existing pattern exactly —
`certificateRef` here must match that `Certificate`'s `spec.secretName`.
The `HTTPRoute` targets PAC's `pipelines-as-code-controller` Service.

### Forgejo repo + webhook setup

**`scripts/forgejo-repo-up.sh`** — idempotent, uses `FORGEJO_TOKEN` against
Forgejo's API (`POST /api/v1/repos/migrate` with `mirror: false`, or a plain
`repos/user/{repo}` create-if-absent check) to ensure a `kind-lab` repo
exists under the token's user/org on `git.local`. Also ensures the local
git remote `forgejo` points at it (`git remote add forgejo
<url> || true`). Mirrors `registry-secret-up.sh`'s "read env var, do the
idempotent thing" shape — no interactive `gh`-style CLI available for
Forgejo, so this talks to the REST API directly with `curl`.

**`scripts/pac-forgejo-secret-up.sh`** — creates the PAC webhook secret and
the Forgejo personal access token Secret in the `pipelines-as-code`
namespace (PAC's documented `Repository` CR references a Secret containing
`webhook.secret` and a token key), reading `FORGEJO_TOKEN` from the
environment. Same idempotent `kubectl create --dry-run=client | kubectl
apply` shape as `datadog-secret-up.sh`. Called from `bootstrap.sh`
alongside the other `*-secret-up.sh` scripts.

**PAC `Repository` CR** (`gitops/apps-templates/`, since it needs the
concrete `git.local` URL and namespace — same reasoning `issuer-up.sh`'s
templates already establish for host-specific values that can't live in a
static Git file): declares the Forgejo repo URL, references the webhook
Secret, and is what PAC watches to know which `.tekton/*.yaml` to run.

### Minimal pipeline

`.tekton/pipelinerun.yaml` at the repo root — PAC's own discovery
convention (any `.tekton/*.yaml` in the pushed branch). One `PipelineRun`
with a single `Task` step that clones the repo (via PAC's injected
`git-clone` params) and runs a trivial command (`echo "pac says hi" && ls`)
to prove the full path works, deliberately not replicating `ci.yml`'s
lint/test/build-push jobs.

## Bootstrap integration

`bootstrap.sh` gains, alongside the existing `*-secret-up.sh` calls:

```
"${SCRIPT_DIR}/forgejo-repo-up.sh"
"${SCRIPT_DIR}/pac-forgejo-secret-up.sh"
```

Both require only `FORGEJO_TOKEN` (already in the env) and `kubectl`/`curl`
— no new manual credential-provisioning step for the user, consistent with
every other `*-up.sh` script in this repo.

## Error handling / risks

- **`.local` mDNS resolution from inside the cluster**: the biggest open
  risk (see "Network assumption" above). If PAC's controller pod can't
  resolve `git.local`, the fix (documenting a CoreDNS forward rule, or an
  `/etc/hosts`-style override via a `HostAliases`/`NodeHosts` entry) is an
  implementation-time fix, not pre-designed here, since the user has
  asserted reachability already works.
- **Webhook secret mismatch**: PAC validates Forgejo's webhook signature
  against the Secret; if `pac-forgejo-secret-up.sh`'s secret and the
  webhook registered on the Forgejo repo diverge, PAC silently rejects
  events — `forgejo-repo-up.sh` and `pac-forgejo-secret-up.sh` must use
  the same secret value, so the webhook secret is generated once (e.g. by
  `pac-forgejo-secret-up.sh`, idempotently) and read by
  `forgejo-repo-up.sh` when it registers the webhook on the Forgejo side.
- **Token scope**: `FORGEJO_TOKEN` needs both repo-admin (to create the
  repo and register a webhook) and repo-read (for PAC to clone) scope —
  documented as a README prerequisite, same treatment as
  `DATADOG_API_KEY`/`GHCR_PULL_TOKEN`.

## Testing / verification bar

Lighter than the full `cluster:down` + `cluster:up` cold-rebuild bar prior
sub-projects were held to (this is explicitly a proof-of-concept, not a
production dependency other sub-projects build on) — but still must be
verified against a real bootstrap:

1. `task cluster:up` succeeds with both new ArgoCD Applications
   `Synced`/`Healthy`.
2. `git push forgejo main` triggers a webhook Forgejo delivers to
   `https://pipelines-as-code.lab.test`.
3. A `PipelineRun` is created in-cluster and reaches `Succeeded`
   (`kubectl get pipelinerun -n pipelines-as-code` or `tkn pac
   resolve`/`tkn pipelinerun logs`).
4. Forgejo's own commit-status UI on `git.local` shows the PAC check result
   (pass/fail) against the pushed commit — this is PAC's standard
   status-reporting behavior and is worth confirming since it's the main
   user-visible proof the integration works.

## Out of scope

- Replacing or touching `.github/workflows/ci.yml`.
- Reopening the Kargo promotion-approval decision (sub-project 3b stays
  Forgejo-free).
- Automatic/scheduled Forgejo mirroring (push is manual for now).
- Replicating the full lint/test/build-push job set in Tekton.
- Tekton Dashboard, Tekton Triggers, or any Tekton UI.
