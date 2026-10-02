# Disabled Applications

Application manifests parked here are deliberately NOT under `gitops/apps/`,
so `root-app` (which only scans `gitops/apps/`, non-recursively) never
applies them. Moving a file back into `gitops/apps/` and pushing to `main`
is all it takes to re-enable it — ArgoCD's own automated sync on `root-app`
picks it up from there.

Currently empty. Datadog was parked here 2026-09-18 to stop host-based
billing and moved back to `gitops/apps/` 2026-10-02 after the account moved
to the Free tier. To park it again: `git mv` both `datadog-*.yaml` here,
push, set `DATADOG_ENABLED=false`, and delete the `datadog` namespace by
hand (removing an Application doesn't cascade-delete what it manages).
