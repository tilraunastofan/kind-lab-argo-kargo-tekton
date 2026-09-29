# Disabled Applications

Application manifests parked here are deliberately NOT under `gitops/apps/`,
so `root-app` (which only scans `gitops/apps/`, non-recursively) never
applies them. Moving a file back into `gitops/apps/` and pushing to `main`
is all it takes to re-enable it — ArgoCD's own automated sync on `root-app`
picks it up from there.

## `datadog-operator.yaml` / `datadog-agent.yaml`

Disabled 2026-09-18 to stop Datadog Infrastructure Monitoring host-based
billing for this lab cluster (temporary, cost-driven — not a design
change). Moving the files back out doesn't fully restore Datadog on its
own: the `datadog` namespace and its contents (DatadogAgent CR, Operator
Deployment, Node/Cluster Agent) were also deleted directly, since removing
an ArgoCD Application object does not cascade-delete the resources it
manages (no `resources-finalizer.argocd.argoproj.io` finalizer is set on
these apps). To re-enable:

```bash
git mv gitops/apps-disabled/datadog-operator.yaml gitops/apps-disabled/datadog-agent.yaml gitops/apps/
git commit -m "chore: re-enable Datadog"
git push origin main
# bootstrap.sh only runs scripts/datadog-secret-up.sh when
# DATADOG_ENABLED=true, so export that (plus DATADOG_API_KEY) for future
# `task cluster:up` runs, and create the Secret now on the running cluster:
export DATADOG_ENABLED=true
./scripts/datadog-secret-up.sh
```

Then wait for ArgoCD (`kubectl -n argocd get applications`) to bring
`datadog-operator` and `datadog-agent` back to `Synced`/`Healthy`.
