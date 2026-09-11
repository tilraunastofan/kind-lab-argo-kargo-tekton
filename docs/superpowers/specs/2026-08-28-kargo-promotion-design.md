# Sub-project 3b: Promotion with Kargo — Design

**Status:** Approved for planning
**Depends on:** Sub-project 3a (demo app + ClickHouse), complete. Sub-project 2
(ArgoCD GitOps), complete — Kargo requires ArgoCD to already be installed.

## Goal

Automate promotion of `event-generator` releases from a new "dev" environment
to the existing "prod" environment (what sub-project 3a built and verified,
now formalized as "prod") using [Kargo](https://kargo.io), ArgoCD's sibling
promotion tool. A new image pushed to `ghcr.io/tilraunastofan/kind-lab/event-generator`
by CI is auto-promoted to dev, gated behind a real app-level health check
before it's eligible for prod, and prod promotion requires a human's explicit
approval via Kargo's own UI/CLI. `task cluster:up` brings this up
automatically, to the same cold-rebuild verification bar every prior
sub-project has been held to.

## Scope decisions made during brainstorming

These were explicitly decided with the user rather than left as open
questions in this spec:

- **Environment topology**: two namespaces on this same single `kind`
  cluster (`demo-app` staying "prod" unchanged, a new `demo-app-dev` for
  "dev") — not a second cluster.
- **Approval mechanism**: Kargo's own native manual-approval on the `prod`
  `Stage` (approved via `kargo promote` or Kargo's dashboard). **No PR-based
  approval flow, and no Forgejo.** This directly answers the README's
  open question ("Claude shall evaluate if we need a Git server with
  Actions enabled (Forgejo)") — the answer is no, Kargo's native approval
  satisfies the requirement without a second Git server or PR workflow.
- **Promotion mechanics**: per-environment values files on `main` (no new
  Git branches), not Kargo's default branch-per-stage quickstart pattern —
  matches every other Application in this repo, all of which live on `main`.
- **Verification rigor**: a real app-level check (Argo Rollouts
  `AnalysisTemplate` hitting `event-generator-dev.lab.test/healthz`), not
  just "did the ArgoCD Application report Healthy" — this is what makes
  the README's "proper app tests" requirement literally true rather than
  a rubber stamp.
- **ClickHouse**: shared between dev and prod (one instance, one
  `demo.events` table) — a lab-scale simplification; not data-integrity
  sensitive here the way a real prod database would be.
- **Existing "prod"**: `demo-app`/`event-generator.yaml`/`values.yaml`
  are **not renamed or restructured** — they already are prod (verified in
  sub-project 3a), and Kargo simply starts managing `values.yaml`'s
  `image.tag` going forward instead of a human bumping it. Only additions,
  no renames, minimizes risk to already-verified state.

## Why Kargo needs its own Git credential (not ArgoCD's)

`scripts/argocd-up.sh`'s deploy key is deliberately **read-only**
(`gh repo deploy-key add` without `-w`/`--allow-write` — see
`register_deploy_key`'s own comment: "gh deploy keys are read-only by
default"). Kargo's promotion mechanism works by *committing* the updated
`image.tag` to Git itself (see "How a promotion actually works" below), so
it needs its own **write**-capable credential. Rather than introduce a new
kind of manual token (a GitHub PAT the user has to create), this sub-project
mirrors ArgoCD's own auto-generated-SSH-deploy-key pattern exactly, just
with write access — zero new manual credential-provisioning burden.

## Why Argo Rollouts is required

Kargo's Stage `verification` field checks Freight health via an Argo
Rollouts `AnalysisTemplate`/`AnalysisRun` — this is Kargo's actual
verification mechanism, not an optional add-on. Installing Argo Rollouts
does **not** require `event-generator` to become a Rollout object; its
`AnalysisTemplate`/`AnalysisRun` CRDs work standalone (a `Job`- or
`web`-provider metric run once, independent of any Rollout's own canary
mechanics) against a plain Kubernetes Deployment, which is what
`helm/event-generator` already is and stays.

## Repo layout

```
gitops/
  apps/
    kargo.yaml                    # Kargo Helm chart install, ns kargo
    argo-rollouts.yaml             # Argo Rollouts Helm chart install, ns argo-rollouts
    kargo-project.yaml             # local chart: Project/Warehouse/PromotionTask/
                                    # Stages/AnalysisTemplate/credential Secrets
    event-generator-dev.yaml       # new: mirrors event-generator.yaml, ns demo-app-dev
helm/
  event-generator/
    values.yaml                   # UNCHANGED path — this is "prod", Kargo now owns image.tag
    values-dev.yaml                # new: same shape, ns demo-app-dev, its own image.tag
  gateway/
    values.yaml                   # append one listener entry: event-generator-dev
  kargo-project/
    Chart.yaml
    values.yaml                    # image repo URL, git repo URL, hostnames
    templates/
      project.yaml                 # Project (promotionPolicies)
      warehouse.yaml                # Warehouse (image subscription)
      promotiontask.yaml            # PromotionTask (git-clone/yaml-update/git-commit/
                                     # git-push/argocd-update steps)
      stage-dev.yaml
      stage-prod.yaml
      analysistemplate.yaml         # AnalysisTemplate (web provider -> /healthz)
scripts/
  kargo-deploy-key-up.sh            # write-enabled sibling of argocd-up.sh's deploy key logic
  kargo-image-cred-up.sh            # creates the kargo.akuity.io/cred-type: image Secret
                                     # from $GHCR_PULL_TOKEN (already a required env var)
```

## Kargo + Argo Rollouts installation

Two more `gitops/apps/` entries, same shape as every prior operator install
in this repo (`clickhouse-operator.yaml`, `datadog-operator.yaml`):

- `gitops/apps/kargo.yaml` — single-source, chart `kargo` from
  `oci://ghcr.io/akuity/kargo-charts/kargo`
  (ArgoCD's OCI `repoURL` convention omits the `oci://` prefix, same as
  `clickhouse-operator.yaml`), `targetRevision: 1.11.2` (confirmed current
  via `helm show chart oci://ghcr.io/akuity/kargo-charts/kargo` on
  2026-08-28), namespace `kargo`.
- `gitops/apps/argo-rollouts.yaml` — single-source, official
  `argo-rollouts` chart, namespace `argo-rollouts`.

Both need an early-ish sync-wave (their CRDs must exist before
`kargo-project.yaml`'s `Warehouse`/`Stage`/`AnalysisTemplate` resources are
applied) — same CRD-before-CR ordering this repo has already solved twice
(`clickhouse-operator`/`clickhouse`, `datadog-operator`/`datadog-agent`).

## Credentials

**`scripts/kargo-deploy-key-up.sh`** — a near-exact copy of
`argocd-up.sh`'s `ensure_deploy_key`/`register_deploy_key` functions
(different key path/title, e.g. `kind-lab-kargo`), with one change: `gh repo
deploy-key add ${DEPLOY_KEY_PATH}.pub --repo ${REPO_SLUG} --title
kind-lab-kargo --allow-write`. The private key is then wrapped into a
`kargo.akuity.io/cred-type: git` Secret in the `kargo` project's namespace
(`kubectl create secret generic ... --from-file=repoURL=... --dry-run=client
| kubectl apply -f -`, same idempotency trick used throughout this repo).

**`scripts/kargo-image-cred-up.sh`** — reads the already-required
`GHCR_PULL_TOKEN` env var (same one `registry-secret-up.sh` uses) and
creates a `kargo.akuity.io/cred-type: image` Secret so the `Warehouse` can
authenticate to the private `event-generator` GHCR package.

## Kargo resources (`helm/kargo-project`)

**Project** (`kargo-project/templates/project.yaml`):
```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: kind-lab
spec:
  promotionPolicies:
    - stage: dev
      autoPromotionEnabled: true
    - stage: prod
      autoPromotionEnabled: false
```

**Warehouse** — subscribes to the private image repo:
```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: event-generator
  namespace: kind-lab
spec:
  subscriptions:
    - image:
        repoURL: ghcr.io/tilraunastofan/kind-lab/event-generator
        imageSelectionStrategy: NewestBuild
```

`imageSelectionStrategy: NewestBuild` (not the default `SemVer`) is
required and confirmed via Kargo's own Go source
(`api/v1alpha1/zz_subscription_types.go`) — `event-generator`'s tags are
git short-SHAs (`scripts/build-and-push.sh`), not semantic versions, and
`NewestBuild` selects by image creation timestamp rather than attempting
(and failing) to parse the tag as semver.

**PromotionTask** — one shared, parameterized task; `dev` and `prod`
Stages both use it, differing only in which values file they write to:
```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: PromotionTask
metadata:
  name: promote-event-generator
  namespace: kind-lab
spec:
  vars:
    - name: valuesFile   # helm/event-generator/values-dev.yaml or values.yaml
  steps:
    - uses: git-clone
      config:
        repoURL: git@github.com:tilraunastofan/kind-lab.git
        checkout:
          - branch: main
            path: ./src
    - uses: yaml-update
      as: update-image
      config:
        path: ./src/${{ vars.valuesFile }}
        updates:
          - key: image.tag
            value: ${{ imageFrom('ghcr.io/tilraunastofan/kind-lab/event-generator').Tag }}
    - uses: git-commit
      as: commit
      config:
        path: ./src
        messageFromSteps: [update-image]
    - uses: git-push
      config:
        path: ./src
    - uses: argocd-update
      config:
        apps:
          - name: ${{ ctx.stage == 'dev' && 'event-generator-dev' || 'event-generator' }}
            sources:
              - repoURL: git@github.com:tilraunastofan/kind-lab.git
                desiredRevision: ${{ outputs.commit.commit }}
```

This is the "commit an updated values file to `main`, then point the
target ArgoCD Application at that exact commit" pattern from Kargo's own
official `akuity/kargo-examples` repo (`02-git-driven/02-helm-driven/`),
adapted to write to `main` directly rather than a per-stage branch — no PR
step (`git-open-pr`/`git-wait-for-pr`, which that same example uses for its
own `prod` stage) since this sub-project deliberately uses Kargo's native
manual approval instead.

**`dev` Stage** — auto-promotes (per the Project's `promotionPolicies`),
verified by the `AnalysisTemplate` before its Freight becomes eligible for
`prod`:
```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: dev
  namespace: kind-lab
spec:
  requestedFreight:
    - origin: {kind: Warehouse, name: event-generator}
      sources: {direct: true}
  promotionTemplate:
    spec:
      vars: [{name: valuesFile, value: helm/event-generator/values-dev.yaml}]
      steps: [{task: {name: promote-event-generator}}]
  verification:
    analysisTemplates:
      - name: event-generator-healthz
```

**`prod` Stage** — only accepts Freight that already passed `dev`'s
verification; promotion itself waits on manual approval (the Project's
`autoPromotionEnabled: false` for `prod`):
```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: prod
  namespace: kind-lab
spec:
  requestedFreight:
    - origin: {kind: Warehouse, name: event-generator}
      sources: {stages: [dev]}
  promotionTemplate:
    spec:
      vars: [{name: valuesFile, value: helm/event-generator/values.yaml}]
      steps: [{task: {name: promote-event-generator}}]
```

**AnalysisTemplate** — the "proper app tests" gate, an HTTP check via Argo
Rollouts' `web` metric provider against dev's `/healthz`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: event-generator-healthz
  namespace: kind-lab
spec:
  metrics:
    - name: healthz
      provider:
        web:
          url: https://event-generator-dev.lab.test/healthz
          jsonPath: "{$}"
      successCondition: result != nil
```
(Exact field shape — e.g. whether a plain 200 status check needs
`successCondition` against an HTTP status field vs. body content — gets
confirmed against the live Argo Rollouts CRD during implementation, the
same way this repo has verified every other third-party CRD's exact field
names via `kubectl apply --dry-run=server` before committing. This spec
fixes the *intent* — hit `/healthz`, gate on success — not a byte-exact
manifest.)

## `event-generator-dev` — the new dev environment

`gitops/apps/event-generator-dev.yaml` mirrors `gitops/apps/event-generator.yaml`
exactly (same two-source shape: `helm/event-generator` chart +
`helm/event-generator/extras` directory source), except:
- `valueFiles: [helm/event-generator/values-dev.yaml]` instead of the
  chart's default `values.yaml`
- `destination.namespace: demo-app-dev` instead of `demo-app`
- extras' `Certificate`/`HTTPRoute` target `event-generator-dev.lab.test`
  instead of `event-generator.lab.test`

`helm/event-generator/values-dev.yaml` starts as a copy of the existing
`values.yaml` (same ClickHouse address — shared instance, per the scope
decision above — same resource requests, different `image.tag`).

`helm/gateway/values.yaml` gets one new entry in its `listeners` list for
`event-generator-dev` (the established "onboarding a new app is a one-line
values append" pattern from `helm/gateway/templates/gateway.yaml`'s
existing comment).

## Bootstrap wiring

Add `kargo-deploy-key-up.sh` and `kargo-image-cred-up.sh` to `bootstrap.sh`,
grouped with `datadog-secret-up.sh`/`registry-secret-up.sh` right after
`argocd-up.sh` — same reasoning as both of those: plain-`kubectl`
operations that only need the cluster to exist, placed early enough that
their Secrets exist before any Kargo-managed resource tries to use them.

`README.md`'s Prerequisites section needs no *new* env var — both
credentials are sourced from things already required
(`GHCR_PULL_TOKEN`) or self-generated (the new deploy key, auto-created and
auto-registered exactly like ArgoCD's).

## Verification

Full `cluster:down` + `cluster:up` cold rebuild (the bar every prior
sub-project has been held to), then a real end-to-end promotion, not just
"the Applications synced":

1. `kubectl -n argocd get applications kargo argo-rollouts kargo-project
   event-generator-dev` — all `Synced`/`Healthy`.
2. Push a new `event-generator` image via the CI pipeline (or
   `scripts/build-and-push.sh` manually) — confirm the `Warehouse`
   discovers it as new Freight (`kargo get freight` / dashboard).
3. Confirm the `dev` Stage auto-promotes, `demo-app-dev`'s `event-generator`
   Deployment rolls to the new tag, and the `AnalysisTemplate` verification
   passes (`kargo get freight` shows the Freight as verified/healthy in
   `dev`).
4. Confirm the `prod` Stage does **not** auto-promote (Freight sits
   available-but-not-promoted, per `autoPromotionEnabled: false`).
5. Manually approve via `kargo promote --project kind-lab --stage prod
   --freight <id>` (or the dashboard) — confirm `demo-app`'s
   `event-generator` (the existing "prod") rolls to the new tag, and
   `https://event-generator.lab.test` reflects it.

## CLAUDE.md status update

Once verification passes, add a "Sub-project 3b, promotion, is complete and
working" paragraph to `CLAUDE.md`'s "Project status" section, following the
established structure — and update the README's now-resolved Forgejo
question (the answer is "not needed," per the scope decision above) so it
no longer reads as an open question.

## Commenting standard

Same learning-lab standard as every prior sub-project: every new
YAML/script file gets comments explaining *why* — especially the parts a
newcomer to Kargo would trip on (why a second deploy key instead of reusing
ArgoCD's, why `NewestBuild` instead of the default `SemVer`, why Argo
Rollouts is required despite `event-generator` not being a Rollout, why
this repo's promotion pattern writes to `main` directly instead of Kargo's
default per-stage-branch quickstart pattern).
