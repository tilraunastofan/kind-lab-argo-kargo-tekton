#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

applications_healthy() {
  local not_healthy
  not_healthy=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' \
    | grep -vc '^Synced Healthy$' || true)
  [ "${not_healthy}" -eq 0 ]
}

verify_https() {
  local host="$1"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' --cacert "${HOME}/.step/certs/root_ca.crt" --max-time 5 "https://${host}" 2>/dev/null || echo "000")
  [ "${status}" = "200" ]
}

main() {
  require_cmd kubectl curl

  wait_for "all ArgoCD Applications Synced and Healthy" 120 applications_healthy
  wait_for "https://argocd.${LAB_DOMAIN} returns 200" 90 verify_https "argocd.${LAB_DOMAIN}"
  wait_for "https://smoke.${LAB_DOMAIN} returns 200" 60 verify_https "smoke.${LAB_DOMAIN}"

  log "smoke test passed: ArgoCD healthy, https://argocd.${LAB_DOMAIN} and https://smoke.${LAB_DOMAIN} both served with a trusted cert"
}

main "$@"
