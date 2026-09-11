#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the Secret Kargo's Warehouse uses to authenticate to
# the private ghcr.io/tilraunastofan/kind-lab-argo-kargo-tekton/event-generator package when
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

  log "ensuring kind-lab namespace exists and is labeled as a Kargo project namespace"
  # kargo.akuity.io/project=true: Kargo's Project admission webhook (v1.11.2)
  # refuses to adopt a pre-existing namespace unless it already carries this
  # label, so it has to be applied here rather than left to the Project
  # resource itself (helm/kargo-project/templates/project.yaml, Task 5) —
  # confirmed against the live cluster's actual webhook error message.
  kubectl create namespace kind-lab --dry-run=client -o yaml \
    | kubectl label --local -f - kargo.akuity.io/project=true -o yaml \
    | kubectl apply -f -

  log "creating/refreshing event-generator-image credential Secret in kind-lab"
  # `create ... --dry-run=client -o yaml | kubectl apply -f -` is an idempotency
  # trick: `kubectl create` alone would fail on a second run ("already exists"),
  # but rendering client-side (--dry-run=client) and piping into `apply` makes
  # this safe to re-run — apply creates on the first run and updates in place on
  # every run after. The `kubectl label --local -f -` step labels the rendered
  # YAML client-side before applying, so the label ends up on the actual object.
  kubectl -n kind-lab create secret generic event-generator-image \
    --from-literal=repoURL="ghcr.io/tilraunastofan/kind-lab-argo-kargo-tekton/event-generator" \
    --from-literal=username="tilraunastofan" \
    --from-literal=password="${GHCR_PULL_TOKEN}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - kargo.akuity.io/cred-type=image -o yaml \
    | kubectl apply -f -

  log "kargo image credential ready in kind-lab"
}

main "$@"
