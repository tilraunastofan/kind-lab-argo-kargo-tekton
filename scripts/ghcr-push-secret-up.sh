#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the ghcr-push Secret (type dockerconfigjson) in the
# pipelines-as-code namespace: the registry credential Tekton's buildah-build
# task uses to PUSH event-generator images to ghcr.io from a push to main.
# Needs a write:packages-scoped GitHub token in GHCR_PUSH_TOKEN (never
# committed; export it in your shell). Deliberately a separate, write-scoped
# credential from ghcr-pull (read-only, registry-secret-up.sh).
# Optional: without the token, the PR build pipeline still works (it only
# builds) and only the push-to-main pipeline fails, with a clear message.
main() {
  require_cmd kubectl

  if [ -z "${GHCR_PUSH_TOKEN:-}" ]; then
    warn "GHCR_PUSH_TOKEN is not set — skipping ghcr-push Secret (image pushes from Tekton will fail until it exists)"
    return 0
  fi

  kubectl create namespace pipelines-as-code --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing ghcr-push Secret in pipelines-as-code"
  kubectl -n pipelines-as-code create secret docker-registry ghcr-push \
    --docker-server=ghcr.io \
    --docker-username=tilraunastofan \
    --docker-password="${GHCR_PUSH_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

main "$@"
