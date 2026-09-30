#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Override (e.g. the Tailscale URL) when this Mac does not trust git.local's Caddy cert.
FORGEJO_URL="${FORGEJO_URL:-https://git.local}"
FORGEJO_REPO_NAME="kind-lab-argo-kargo-tekton"

# Ensures a kind-lab-argo-kargo-tekton repo exists on the user's
# self-hosted Forgejo instance (git.local, on the same LAN) as a regular,
# STANDALONE repo (not a pull mirror: mirrors are read-only in Forgejo, so
# they can't take PRs, which is what the Tekton demo needs). GitHub stays
# ArgoCD's source; push to Forgejo too with `git push forgejo main` (or a
# feature branch + PR) to trigger Pipelines-as-Code. A webhook is then
# registered against the repo, pointing at PAC's controller.
#
# Requires FORGEJO_TOKEN (a Forgejo personal access token with
# Repository:Write/Issue:Write scopes) for talking to Forgejo's API.
#
# Uses curl directly against Forgejo's REST API (Gitea-API-compatible v1).

forgejo_api() {
  curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

main() {
  require_cmd kubectl curl jq

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first"
  fi

  log "looking up Forgejo username for the token"
  local owner
  owner="$(forgejo_api "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
  [ -n "${owner}" ] && [ "${owner}" != "null" ] || die "could not determine Forgejo username — check FORGEJO_TOKEN and ${FORGEJO_URL} reachability"

  # Checked via the API, not the web UI path: a private repo's web page
  # 404s under token auth even when it exists, which would make this
  # non-idempotent.
  local repo_json
  if repo_json="$(forgejo_api "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}" 2>/dev/null)"; then
    if [ "$(jq -r '.mirror' <<<"${repo_json}")" = "true" ]; then
      die "${owner}/${FORGEJO_REPO_NAME} is still a pull mirror (read-only, no PRs). Convert it to a regular repo in Forgejo (Settings) or delete it, then re-run."
    fi
    log "repo ${owner}/${FORGEJO_REPO_NAME} already exists on ${FORGEJO_URL}, skipping creation"
  else
    log "creating standalone repo ${owner}/${FORGEJO_REPO_NAME} on ${FORGEJO_URL}"
    forgejo_api -X POST "${FORGEJO_URL}/api/v1/user/repos" \
      -d "{\"name\": \"${FORGEJO_REPO_NAME}\", \"private\": true, \"default_branch\": \"main\", \"auto_init\": false}" >/dev/null
  fi

  log "reading webhook shared secret from pac-forgejo-creds"
  local webhook_secret
  webhook_secret="$(kubectl -n pipelines-as-code get secret pac-forgejo-creds \
    -o jsonpath='{.data.webhook\.secret}' | base64 -d)"
  [ -n "${webhook_secret}" ] || die "pac-forgejo-creds has no webhook.secret key — run pac-forgejo-secret-up.sh first"

  log "checking for an existing webhook on ${owner}/${FORGEJO_REPO_NAME}"
  local existing_hook_id
  existing_hook_id="$(forgejo_api "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}/hooks" \
    | jq -r '.[] | select(.config.url == "https://pipelines-as-code.tekton-lab.test") | .id' | head -1)"

  local hook_payload
  hook_payload=$(cat <<EOF
{
  "type": "forgejo",
  "active": true,
  "config": {
    "url": "https://pipelines-as-code.tekton-lab.test",
    "content_type": "json",
    "secret": "${webhook_secret}"
  },
  "events": ["push", "pull_request", "issue_comment"]
}
EOF
)

  if [ -n "${existing_hook_id}" ]; then
    log "updating existing webhook (id ${existing_hook_id}) on ${owner}/${FORGEJO_REPO_NAME}"
    forgejo_api -X PATCH \
      "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}/hooks/${existing_hook_id}" \
      -d "${hook_payload}" >/dev/null
  else
    log "registering webhook on ${owner}/${FORGEJO_REPO_NAME}"
    forgejo_api -X POST \
      "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}/hooks" \
      -d "${hook_payload}" >/dev/null
  fi

  log "repo + webhook ready: ${FORGEJO_URL}/${owner}/${FORGEJO_REPO_NAME} — push with: git remote add forgejo ${FORGEJO_URL}/${owner}/${FORGEJO_REPO_NAME}.git && git push forgejo main"
}

main "$@"
