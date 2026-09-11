#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the pac-forgejo-creds Secret in the pipelines-as-code
# namespace: the Forgejo personal access token PAC's controller uses to
# talk back to the Forgejo API (post commit statuses, fetch PipelineRun
# definitions from the pushed branch), and a webhook shared secret PAC
# uses to validate that incoming webhook deliveries actually came from
# Forgejo (HMAC-SHA256 over the payload). Requires FORGEJO_TOKEN in the
# environment (not committed to Git — same treatment as
# DATADOG_API_KEY/GHCR_PULL_TOKEN).
#
# The webhook secret is generated once and kept stable across reruns
# (rather than regenerated every time) because scripts/forgejo-repo-up.sh
# (Task 3) reads it back out of this same Secret to register the matching
# webhook secret value on the Forgejo side — the two must always agree, or
# PAC silently rejects every webhook delivery.

main() {
  require_cmd kubectl openssl

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first (Repository:Write, Issue:Write scopes)"
  fi

  log "ensuring pipelines-as-code namespace exists"
  kubectl create namespace pipelines-as-code --dry-run=client -o yaml | kubectl apply -f -

  local webhook_secret
  webhook_secret="$(kubectl -n pipelines-as-code get secret pac-forgejo-creds \
    -o jsonpath='{.data.webhook\.secret}' 2>/dev/null | base64 -d || true)"
  if [ -z "${webhook_secret}" ]; then
    log "generating new webhook shared secret"
    webhook_secret="$(openssl rand -hex 20)"
  else
    log "reusing existing webhook shared secret"
  fi

  log "creating/refreshing pac-forgejo-creds in pipelines-as-code"
  kubectl -n pipelines-as-code create secret generic pac-forgejo-creds \
    --from-literal=token="${FORGEJO_TOKEN}" \
    --from-literal=webhook.secret="${webhook_secret}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "pac-forgejo-creds ready in pipelines-as-code"
}

main "$@"
