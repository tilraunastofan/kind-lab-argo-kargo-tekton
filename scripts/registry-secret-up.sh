#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the ghcr-pull imagePullSecret in the demo-app namespace,
# used by helm/event-generator's Deployment to pull private ghcr.io images.
# Requires a read:packages-scoped GitHub token in GHCR_PULL_TOKEN (not
# committed to Git — export it in your shell before running this).
#
# Why this exists at all: Kubernetes doesn't know how to authenticate to a
# private registry on its own. A Secret of type kubernetes.io/dockerconfigjson
# (which `kubectl create secret docker-registry` builds for us) holds
# registry credentials in the same format as a local ~/.docker/config.json;
# a Pod referencing it via imagePullSecrets lets the kubelet use those
# credentials when pulling the image. This script is deliberately separate
# from build-and-push.sh (Task 12) — pushing needs *write* access, pulling
# only needs *read* access, so they use differently-scoped tokens on
# purpose (least privilege: the credential baked into the cluster can only
# read images, never publish or delete them).

main() {
  require_cmd kubectl

  if [ -z "${GHCR_PULL_TOKEN:-}" ]; then
    die "GHCR_PULL_TOKEN is not set — export a read:packages-scoped GitHub token first"
  fi

  # `create ... --dry-run=client -o yaml | kubectl apply -f -` is a common
  # idempotency trick: `kubectl create` alone would fail on a second run
  # ("already exists"), but rendering it client-side (--dry-run=client,
  # meaning "just print the YAML this *would* create, don't actually talk
  # to the apiserver") and piping into `apply` makes the whole thing safe
  # to re-run — apply creates on the first run and updates in place on
  # every run after. Same pattern used for the namespace below.
  # demo-app-dev (sub-project 3b's Kargo-managed "dev" environment) needs
  # the exact same imagePullSecret demo-app ("prod") already does — same
  # private image, different namespace, and imagePullSecrets only work
  # within the Pod's own namespace, so this can't be shared across the two.
  local ns
  for ns in demo-app demo-app-dev; do
    log "ensuring ${ns} namespace exists"
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -

    log "creating/refreshing ghcr-pull imagePullSecret in ${ns}"
    kubectl -n "${ns}" create secret docker-registry ghcr-pull \
      --docker-server=ghcr.io \
      --docker-username=tilraunastofan \
      --docker-password="${GHCR_PULL_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -

    log "ghcr-pull secret ready in ${ns}"
  done
}

main "$@"
