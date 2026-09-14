#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

main() {
  require_cmd kind kubectl docker

  if cluster_exists; then
    log "kind cluster '${CLUSTER_NAME}' already exists, skipping creation"
  else
    log "creating kind cluster '${CLUSTER_NAME}'"
    kind create cluster --config "${REPO_ROOT}/cluster/kind-config.yaml"
  fi

  kubectl cluster-info --context "kind-${CLUSTER_NAME}"
}

main "$@"
