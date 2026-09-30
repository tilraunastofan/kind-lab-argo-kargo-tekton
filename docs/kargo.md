# Kargo in the lab

Kargo promotes the `event-generator` image from **dev** to **prod**. The UI is at
**https://kargo.tekton-lab.test**. Everything can be done three ways: the UI, the
`kargo` CLI (`brew install kargo`), or plain `kubectl`, because Kargo's objects are
ordinary Kubernetes resources. The `kubectl` versions come first below; the CLI
versions are in [Using the `kargo` CLI](#using-the-kargo-cli).

All Kargo objects live in the project namespace **`kind-lab`** (add `-n kind-lab` or
set it once: `kubectl config set-context --current --namespace=kind-lab`).

## The moving parts

| Kargo object | Name | What it is |
|---|---|---|
| Warehouse | `event-generator` | Watches ghcr.io for new `event-generator` image tags. Each new tag becomes **Freight**. |
| Freight | (random alias, e.g. `honking-lobster`) | One promotable version: the image tag + digest. |
| Stage `dev` | | Runs Freight in `demo-app-dev`. **Promotes automatically.** |
| Stage `prod` | | Runs Freight in `demo-app`. **Manual**, and only Freight that has gone through dev. |
| Promotion | `dev.<id>.<sha>` | A record of "put this Freight on this Stage". |

The full loop: push to `main` → Tekton builds and pushes the image (see
[tekton.md](tekton.md)) → Warehouse discovers the tag → Freight → `dev` promotes it
automatically → you promote it to `prod`.

## See what's going on

```bash
# What versions exist, and where is each one deployed?
kubectl -n kind-lab get freight
kubectl -n kind-lab get stages
```

`get stages` shows each Stage's current Freight and whether it is healthy
(`READY`/`STATUS`). `get freight` lists every version with its alias and age.

Which image tag is actually running?

```bash
kubectl get deploy event-generator -n demo-app-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'  # dev
kubectl get deploy event-generator -n demo-app     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'  # prod
```

Tag → Freight (which alias is tag `c0dd860`?):

```bash
kubectl -n kind-lab get freight -o jsonpath='{range .items[*]}{.alias}  {.images[0].tag}  {.metadata.creationTimestamp}{"\n"}{end}'
```

Promotion history and outcome:

```bash
kubectl -n kind-lab get promotions
```

`PHASE` is `Succeeded`, `Running` or `Failed`; `kubectl -n kind-lab describe promotion <name>`
shows the steps and any error.

## Make Kargo notice a new image now

The Warehouse polls ghcr.io on an interval. To check immediately after a build:

```bash
kubectl -n kind-lab annotate warehouse event-generator kargo.akuity.io/refresh="$(date +%s)" --overwrite
kubectl -n kind-lab get freight     # the new tag appears within seconds
```

(In the UI: open the Warehouse and click refresh.)

## Promote to prod

`dev` promotes by itself; `prod` waits for you. In the UI, open the Freight and choose
*Promote* → `prod`. With `kubectl`, create a `Promotion`:

```bash
FREIGHT=$(kubectl -n kind-lab get freight -o jsonpath='{.items[?(@.alias=="honking-lobster")].metadata.name}')

kubectl create -f - <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  generateName: prod-
  namespace: kind-lab
spec:
  stage: prod
  freight: ${FREIGHT}
EOF
```

Replace `honking-lobster` with the alias from `get freight`. Use `create`, not `apply`
(`generateName`). Afterwards watch it with `kubectl -n kind-lab get promotions -w`; when
it `Succeeded`, ArgoCD rolls out the new tag in `demo-app`.

The same manifest with `stage: dev` promotes to dev by hand (normally unnecessary).

## Using the `kargo` CLI

Friendlier than raw `kubectl` (shorter output, one-command promotion). Install with
`brew install kargo`.

> Status: the syntax below comes from `kargo --help` (v1.12.0) and is not yet
> confirmed against this lab's server, because that needs the admin password.
> `kargo login --kubeconfig` does **not** work here (verified): it needs a bearer/OIDC
> token in your kubeconfig, and kind's kubeconfig uses client certificates.

### Log in (once; the token lasts 24h)

```bash
kargo login https://kargo.tekton-lab.test --admin      # asks for the admin password
kargo config set-project kind-lab                      # so you can leave out --project
```

The admin password was printed once by `scripts/kargo-admin-up.sh` during bootstrap
(only its hash is stored in the `kargo-admin` Secret in namespace `kargo`). If it is
lost, delete that Secret and re-run `scripts/kargo-admin-up.sh` to generate a new one
(then restart the `kargo-api` Deployment so it picks it up).

### Look around

```bash
kargo get stages                 # health + current Freight per stage
kargo get freight                # every version, with its alias
kargo get promotions             # history; add --stage=prod to filter
kargo get warehouses
```

Without `set-project`, add `--project=kind-lab` to each command.

### Check for a new image now

```bash
kargo refresh warehouse event-generator
```

### Promote to prod

```bash
kargo promote --freight-alias=honking-lobster --stage=prod
```

Use the alias from `kargo get freight`. `--freight=<full name>` also works. To promote
whatever Freight the Warehouse would choose automatically, use
`kargo promote --warehouse=event-generator --stage=prod`. To cancel a running
promotion: `kargo promote --name=<promotion-name> --abort`.

## Troubleshooting

| Symptom | Check |
|---|---|
| New image pushed but no new Freight | `kubectl -n kind-lab describe warehouse event-generator` (discovery errors, e.g. bad registry credentials: Kargo uses the `event-generator-image` Secret), then refresh as above. |
| Stage `READY False` / Promotion stuck `Running` | `kubectl -n kind-lab describe promotion <name>`; look at the failing step. A promotion edits `helm/event-generator/values*.yaml` in Git and waits for ArgoCD, so it also needs the Kargo deploy key to have write access (`scripts/kargo-deploy-key-up.sh`). |
| Freight exists but prod can't take it | Prod only accepts Freight that has been through `dev` (verified there). Check the dev Stage's health. |
| Promotion succeeded but app not updated | Check the matching ArgoCD Application (`event-generator` / `event-generator-dev`) in https://argocd.tekton-lab.test. |
