#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Generates (if needed) and registers a SECOND SSH deploy key on this repo,
# distinct from argocd-up.sh's — that one is deliberately read-only ("gh
# deploy keys are read-only by default", see argocd-up.sh's own comment),
# but Kargo's promotion mechanism works by *committing* an updated
# image.tag to Git itself, so it needs write access. Wraps the resulting
# private key into a kargo.akuity.io/cred-type: git Secret, the label
# Kargo's controller looks for when a Warehouse/Stage needs Git credentials
# for a repoURL matching this Secret's data.
#
# Mirrors argocd-up.sh's ensure_deploy_key/register_deploy_key functions
# almost exactly — same idempotency reasoning, same gh CLI calls — just a
# different key path/title and --allow-write on registration.

DEPLOY_KEY_PATH="${HOME}/.ssh/kind-lab-argo-kargo-tekton-kargo"
REPO_SLUG="tilraunastofan/kind-lab-argo-kargo-tekton"

ensure_deploy_key() {
  if [ -f "${DEPLOY_KEY_PATH}" ]; then
    log "kargo deploy key already exists at ${DEPLOY_KEY_PATH}, skipping generation"
    return 0
  fi
  log "generating kargo deploy key at ${DEPLOY_KEY_PATH}"
  ssh-keygen -t ed25519 -N "" -C "kind-lab-argo-kargo-tekton-kargo" -f "${DEPLOY_KEY_PATH}" >/dev/null
}

local_deploy_key_fingerprint() {
  ssh-keygen -lf "${DEPLOY_KEY_PATH}.pub" | awk '{print $2}'
}

deploy_key_title_ids() {
  gh api "repos/${REPO_SLUG}/keys" --paginate \
    --jq '.[] | select(.title == "kind-lab-argo-kargo-tekton-kargo") | .id' 2>/dev/null
}

deploy_key_registered() {
  local id fingerprint remote_fingerprint local_fingerprint
  local_fingerprint="$(local_deploy_key_fingerprint)"
  while IFS= read -r id; do
    [ -z "${id}" ] && continue
    remote_fingerprint=$(gh api "repos/${REPO_SLUG}/keys/${id}" --jq '.key' 2>/dev/null | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')
    [ "${remote_fingerprint}" = "${local_fingerprint}" ] && return 0
  done < <(deploy_key_title_ids)
  return 1
}

register_deploy_key() {
  if deploy_key_registered; then
    log "kargo deploy key already registered on ${REPO_SLUG}, skipping"
    return 0
  fi
  local stale_id
  while IFS= read -r stale_id; do
    [ -z "${stale_id}" ] && continue
    warn "stale deploy key titled kind-lab-argo-kargo-tekton-kargo on ${REPO_SLUG} doesn't match local key at ${DEPLOY_KEY_PATH}, deleting id ${stale_id}"
    gh repo deploy-key delete "${stale_id}" --repo "${REPO_SLUG}"
  done < <(deploy_key_title_ids)
  log "registering WRITE-enabled deploy key on ${REPO_SLUG}"
  gh repo deploy-key add "${DEPLOY_KEY_PATH}.pub" --repo "${REPO_SLUG}" --title kind-lab-argo-kargo-tekton-kargo --allow-write
}

main() {
  require_cmd kubectl gh ssh-keygen

  ensure_deploy_key
  register_deploy_key

  log "ensuring kind-lab namespace exists and is labeled as a Kargo project namespace"
  # kargo.akuity.io/project=true: Kargo's Project admission webhook (v1.11.2)
  # refuses to adopt a pre-existing namespace unless it already carries this
  # label, so it has to be applied here rather than left to the Project
  # resource itself (helm/kargo-project/templates/project.yaml, Task 5) —
  # confirmed against the live cluster's actual webhook error message.
  kubectl create namespace kind-lab --dry-run=client -o yaml \
    | kubectl label --local -f - kargo.akuity.io/project=true -o yaml \
    | kubectl apply -f -

  log "creating/refreshing event-generator-repo git credential Secret in kind-lab"
  kubectl -n kind-lab create secret generic event-generator-repo \
    --from-literal=repoURL="git@github.com:tilraunastofan/kind-lab-argo-kargo-tekton.git" \
    --from-file=sshPrivateKey="${DEPLOY_KEY_PATH}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml \
    | kubectl apply -f -

  log "kargo git credential ready in kind-lab"
}

main "$@"
