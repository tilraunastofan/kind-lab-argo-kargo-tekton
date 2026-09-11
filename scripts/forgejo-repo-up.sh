#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_URL="https://git.local"
FORGEJO_REPO_NAME="kind-lab-argo-kargo-tekton"

# Ensures a kind-lab repo exists on the user's self-hosted Forgejo instance
# (git.local, on the same LAN), with a webhook registered against it
# pointing at Pipelines-as-Code's controller, and a local `forgejo` git
# remote so `git push forgejo main` can trigger it. Requires FORGEJO_TOKEN
# (a Forgejo personal access token with Repository:Write/Issue:Write
# scopes) and pac-forgejo-creds (Task 2's Secret, for the webhook shared
# secret — the webhook registered here and the Secret PAC reads from must
# agree, or every delivery is silently rejected).
#
# Uses curl directly against Forgejo's REST API (Gitea-API-compatible v1)
# rather than a dedicated CLI — unlike GitHub, there's no `gh`-equivalent
# already a prerequisite in this repo.

forgejo_api() {
  curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

main() {
  require_cmd kubectl curl jq git

  if [ -z "${FORGEJO_TOKEN:-}" ]; then
    die "FORGEJO_TOKEN is not set — export a Forgejo personal access token first"
  fi

  log "looking up Forgejo username for the token"
  local owner
  owner="$(forgejo_api "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
  [ -n "${owner}" ] && [ "${owner}" != "null" ] || die "could not determine Forgejo username — check FORGEJO_TOKEN and ${FORGEJO_URL} reachability"

  local repo_url="${FORGEJO_URL}/${owner}/${FORGEJO_REPO_NAME}"

  # Check via the API (not the web UI path): Forgejo's web routes don't
  # honor the `Authorization: token ...` header the same way the API does,
  # so a private repo's web page 404s even when it exists — checking the
  # web path here made repo creation non-idempotent (every re-run tried to
  # create an already-existing repo and errored out).
  if forgejo_api "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}" -o /dev/null 2>/dev/null; then
    log "repo ${owner}/${FORGEJO_REPO_NAME} already exists on ${FORGEJO_URL}, skipping creation"
  else
    log "creating repo ${owner}/${FORGEJO_REPO_NAME} on ${FORGEJO_URL}"
    forgejo_api -X POST "${FORGEJO_URL}/api/v1/user/repos" \
      -d "{\"name\": \"${FORGEJO_REPO_NAME}\", \"private\": true}" >/dev/null
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

  log "ensuring local git remote 'forgejo' points at ${repo_url}"
  if git remote get-url forgejo >/dev/null 2>&1; then
    git remote set-url forgejo "${repo_url}.git"
  else
    git remote add forgejo "${repo_url}.git"
  fi

  log "forgejo remote ready: ${repo_url}.git (push with: git push forgejo main)"
}

main "$@"
