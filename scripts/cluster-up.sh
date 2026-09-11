#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CPK_ERR_LOG="/var/log/cloud-provider-kind.err.log"
CPK_LAUNCHD_LABEL="system/com.kind.cloud-provider-kind"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

# current_apiserver_port: the host port docker currently maps to the
# cluster's control-plane API server (6443/tcp), or empty if unknown.
current_apiserver_port() {
  docker port "${CLUSTER_NAME}-control-plane" 6443/tcp 2>/dev/null | tail -1 | sed -E 's/.*:([0-9]+)$/\1/'
}

# cpk_connected_to_current_cluster: true if cloud-provider-kind's own log
# shows its most recent successful connection for this cluster name points
# at the API server port docker currently reports.
#
# Why this check exists: cloud-provider-kind is a long-lived root
# LaunchDaemon that's meant to persist across `kind delete cluster` /
# `kind create cluster` cycles (and Docker runtime restarts). Whenever the
# control-plane container gets a new host port — cluster recreation, or the
# underlying Docker runtime (e.g. OrbStack) restarting — cloud-provider-kind
# does not always notice and can get stuck retrying the *stale* port
# indefinitely (confirmed in practice from both triggers: "connection
# refused" against the old port for 5+ minutes with no self-healing after a
# `kind delete`+`create` cycle, and again after an OrbStack restart). See
# task-3b-report.md for the reproductions.
cpk_connected_to_current_cluster() {
  local actual_port last_line last_port
  actual_port="$(current_apiserver_port)"
  [ -n "${actual_port}" ] || return 0 # can't determine target port; don't block on it

  [ -r "${CPK_ERR_LOG}" ] || return 0 # log unreadable; best-effort, don't block

  last_line="$(grep -a '"Connected successfully"' "${CPK_ERR_LOG}" 2>/dev/null \
    | grep -F "cluster=\"${CLUSTER_NAME}\"" | tail -1)"
  [ -n "${last_line}" ] || return 1 # cpk running but never connected to this cluster name

  last_port="$(printf '%s' "${last_line}" | sed -E 's/.*host="https:\/\/[^:]+:([0-9]+)".*/\1/')"
  [ "${last_port}" = "${actual_port}" ]
}

verify_cloud_provider_kind() {
  pgrep -x cloud-provider-kind >/dev/null 2>&1 || return 0 # not our concern here

  log "checking cloud-provider-kind is connected to the current cluster's API server"
  local elapsed=0 timeout=30
  until cpk_connected_to_current_cluster; do
    if [ "${elapsed}" -ge "${timeout}" ]; then
      warn "cloud-provider-kind (root LaunchDaemon) appears stuck on a stale connection from a previous cluster instance."
      warn "This happens because it keeps running across cluster recreation and Docker runtime restarts, and can miss that the API server got a new port. It will not self-heal automatically."
      echo
      echo "  sudo launchctl kickstart -k ${CPK_LAUNCHD_LABEL}"
      echo
      die "run the command above, then re-run this script (Gateway/LoadBalancer Services will stay <pending> until it does)"
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  log "cloud-provider-kind connected to '${CLUSTER_NAME}': ready"
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

  verify_cloud_provider_kind
}

main "$@"
