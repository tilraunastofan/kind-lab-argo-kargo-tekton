# Kargo approaches

Confirmed the concrete mechanics: Kargo installs via oci://ghcr.io/akuity/kargo-charts/kargo (current v1.11.2), requires ArgoCD (already have it), and its idiomatic promotion pattern is "commit an updated values file to Git → ArgoCD syncs" — which fits this repo's existing all-through-Git philosophy perfectly. One important finding: ArgoCD's existing deploy key is read-only by design (gh repo deploy-key add without -w), so Kargo needs its own separate write-capable credential — I'll mirror the same auto-generated-SSH-deploy-key pattern already used for ArgoCD, just with --allow-write, so no new manual token is needed from you.

## Approaches

### Approach A (recommended) — single-branch, per-environment values files

Two ArgoCD Applications (event-generator-dev, event-generator-prod), each sourcing helm/event-generator with its own values file (values-dev.yaml, values-prod.yaml), both still on main — no new branches. A Kargo Warehouse subscribes to the GHCR image repo (`ghcr.io/tilraunastofan/kind-lab-argo-kargo-tekton/event-generator` in this repo); the dev Stage auto-promotes new Freight (commits the new tag to values-dev.yaml); a lightweight verification step (Argo Rollouts AnalysisTemplate hitting /healthz, maybe a load-trigger + row-count check) gates whether that Freight is eligible for prod; the prod Stage requires manual approval via Kargo's UI/CLI before promoting the same tag into values-prod.yaml.

### Approach B — Kargo's own branch-per-stage default pattern

Kargo's quickstart default: an ApplicationSet templates one Application per Stage, each tracking a different Git branch (stage/dev, stage/prod) rather than different files on main. More "out of the box," but introduces a branching model this repo has never used (everything else lives on main only) — more moving parts for no real benefit at this scale.

I recommend A — it's simpler and matches every other Application in this repo.

## Notes for this repo (kind-lab-argo-kargo-tekton)

Kargo's dashboard/API has no Ingress exposure in this lab (same as the original `kind-lab` before the ingress-nginx swap) — access it via `kubectl port-forward`, per whatever Kargo admin script/task is wired up in `scripts/kargo-admin-up.sh`. Since it's port-forward-only, the Cilium→ingress-nginx networking swap elsewhere in this repo doesn't change anything here.
