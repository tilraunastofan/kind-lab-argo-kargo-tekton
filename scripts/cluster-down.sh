#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

main() {
  require_cmd kind

  if cluster_exists; then
    kind delete cluster --name "${CLUSTER_NAME}"
  else
    log "kind cluster '${CLUSTER_NAME}' does not exist, skipping deletion"
  fi
}

main "$@"
