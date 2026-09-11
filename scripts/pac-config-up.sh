#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_URL="https://git.local"

app_healthy() {
  local sync health
  sync=$(kubectl -n argocd get application pipelines-as-code-config -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application pipelines-as-code-config -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]
}

main() {
  require_cmd kubectl envsubst curl jq

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first"
  fi

  log "looking up Forgejo username for the token"
  export FORGEJO_OWNER
  FORGEJO_OWNER="$(curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
  [ -n "${FORGEJO_OWNER}" ] && [ "${FORGEJO_OWNER}" != "null" ] || die "could not determine Forgejo username"

  log "applying pipelines-as-code-config Application (repo owner: ${FORGEJO_OWNER})"
  envsubst '${FORGEJO_OWNER}' \
    < "${SCRIPT_DIR}/../gitops/apps-templates/pipelines-as-code-config.yaml.tmpl" | kubectl apply -f -

  wait_for "pipelines-as-code-config Application Synced and Healthy" 90 app_healthy
}

main "$@"
