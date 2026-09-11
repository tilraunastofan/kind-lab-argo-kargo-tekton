#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

app_healthy() {
  local sync health
  sync=$(kubectl -n argocd get application cluster-issuer -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application cluster-issuer -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]
}

issuer_ready() {
  [ "$(kubectl get clusterissuer step-ca-acme -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

main() {
  require_cmd kubectl envsubst scutil openssl base64

  local host
  host="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
  export STEPCA_HOST="${host}"
  export STEPCA_PORT
  export STEPCA_ROOT_CA_B64
  STEPCA_ROOT_CA_B64=$(base64 < "${HOME}/.step/certs/root_ca.crt" | tr -d '\n')

  log "applying cluster-issuer Application (server https://${STEPCA_HOST}:${STEPCA_PORT}/acme/acme/directory)"
  envsubst '${STEPCA_HOST} ${STEPCA_PORT} ${STEPCA_ROOT_CA_B64}' \
    < "${SCRIPT_DIR}/../gitops/apps-templates/cluster-issuer.yaml.tmpl" | kubectl apply -f -

  wait_for "cluster-issuer Application Synced and Healthy" 90 app_healthy
  wait_for "ClusterIssuer step-ca-acme Ready" 60 issuer_ready
}

main "$@"
