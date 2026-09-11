#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_URL="https://git.local"
FORGEJO_REPO_NAME="kind-lab-argo-kargo-tekton"
GITHUB_CLONE_URL="https://github.com/tilraunastofan/kind-lab-argo-kargo-tekton.git"

# Ensures a kind-lab-argo-kargo-tekton repo exists on the user's
# self-hosted Forgejo instance (git.local, on the same LAN) as a PULL
# MIRROR of this GitHub repo — Forgejo periodically re-pulls main on its
# own after a `git push` to GitHub, no `git push forgejo main` step to
# remember (unlike the original kind-lab, which used a manually-pushed
# second remote — this repo's Forgejo copy is purely a webhook-delivery
# source for Tekton Pipelines-as-Code, so a passive mirror is simpler and
# just as effective). A webhook is then registered against the mirror
# repo, same as before, pointing at PAC's controller.
#
# Mirroring a *private* GitHub repo needs read credentials Forgejo can use
# when it pulls — GITHUB_MIRROR_TOKEN (a GitHub PAT scoped to `repo` read,
# or `gh auth token` for a quick one) supplies that. Requires FORGEJO_TOKEN
# (a Forgejo personal access token with Repository:Write/Issue:Write
# scopes) for talking to Forgejo's own API, same as always.
#
# Uses curl directly against Forgejo's REST API (Gitea-API-compatible v1)
# rather than a dedicated CLI — same reasoning as before.

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
  if [ -z "${GITHUB_MIRROR_TOKEN:-}" ]; then
    die "GITHUB_MIRROR_TOKEN is not set — export a GitHub token with read access to this repo (e.g. \$(gh auth token)) first"
  fi

  log "looking up Forgejo username for the token"
  local owner
  owner="$(forgejo_api "${FORGEJO_URL}/api/v1/user" | jq -r '.login')"
  [ -n "${owner}" ] && [ "${owner}" != "null" ] || die "could not determine Forgejo username — check FORGEJO_TOKEN and ${FORGEJO_URL} reachability"

  # Checked via the API, not the web UI path, for the same reason the
  # original script documents: a private repo's web page 404s under
  # token auth even when it exists, which would make this non-idempotent.
  if forgejo_api "${FORGEJO_URL}/api/v1/repos/${owner}/${FORGEJO_REPO_NAME}" -o /dev/null 2>/dev/null; then
    log "mirror repo ${owner}/${FORGEJO_REPO_NAME} already exists on ${FORGEJO_URL}, skipping creation"
  else
    log "creating ${owner}/${FORGEJO_REPO_NAME} on ${FORGEJO_URL} as a pull mirror of ${GITHUB_CLONE_URL}"
    forgejo_api -X POST "${FORGEJO_URL}/api/v1/repos/migrate" \
      -d "{\"clone_addr\": \"${GITHUB_CLONE_URL}\", \"auth_token\": \"${GITHUB_MIRROR_TOKEN}\", \"repo_name\": \"${FORGEJO_REPO_NAME}\", \"repo_owner\": \"${owner}\", \"mirror\": true, \"mirror_interval\": \"10m0s\", \"private\": true}" >/dev/null
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

  log "mirror + webhook ready: ${FORGEJO_URL}/${owner}/${FORGEJO_REPO_NAME} (pulls main from GitHub automatically; no manual push needed)"
}

main "$@"
