#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ARGOCD_CHART_VERSION="10.4.0"
DEPLOY_KEY_PATH="${HOME}/.ssh/kind-lab-argocd-deploy"
REPO_SSH_URL="git@github.com:tilraunastofan/kind-lab-argo-kargo-tekton.git"
REPO_SLUG="tilraunastofan/kind-lab-argo-kargo-tekton"

install_argocd() {
  log "installing ArgoCD ${ARGOCD_CHART_VERSION}"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --version "${ARGOCD_CHART_VERSION}" \
    --namespace argocd --create-namespace \
    --values "${SCRIPT_DIR}/../helm/argocd/values.yaml" \
    --kube-context "kind-${CLUSTER_NAME}" \
    --wait --timeout 5m
}

ensure_deploy_key() {
  if [ -f "${DEPLOY_KEY_PATH}" ]; then
    log "deploy key already exists at ${DEPLOY_KEY_PATH}, skipping generation"
    return 0
  fi
  log "generating deploy key at ${DEPLOY_KEY_PATH}"
  ssh-keygen -t ed25519 -N "" -C "kind-lab-argocd" -f "${DEPLOY_KEY_PATH}" >/dev/null
}

local_deploy_key_fingerprint() {
  ssh-keygen -lf "${DEPLOY_KEY_PATH}.pub" | awk '{print $2}'
}

# Returns success only if a registered GitHub deploy key's public key material
# (not just its title) matches the local key. A stale key with a matching
# title but different material (e.g. after the local key was regenerated)
# does NOT count as registered.
deploy_key_registered() {
  local local_fp remote_key remote_fp
  local_fp="$(local_deploy_key_fingerprint)"
  while IFS= read -r remote_key; do
    [ -z "${remote_key}" ] && continue
    remote_fp="$(printf '%s\n' "${remote_key}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
    if [ -n "${remote_fp}" ] && [ "${remote_fp}" = "${local_fp}" ]; then
      return 0
    fi
  done < <(gh repo deploy-key list --repo "${REPO_SLUG}" --json key --jq '.[].key' 2>/dev/null)
  return 1
}

deploy_key_title_ids() {
  gh repo deploy-key list --repo "${REPO_SLUG}" --json id,title \
    --jq '.[] | select(.title == "kind-lab-argocd") | .id' 2>/dev/null
}

register_deploy_key() {
  if deploy_key_registered; then
    log "deploy key already registered on ${REPO_SLUG}, skipping"
    return 0
  fi
  local stale_id
  while IFS= read -r stale_id; do
    [ -z "${stale_id}" ] && continue
    warn "stale deploy key titled kind-lab-argocd on ${REPO_SLUG} doesn't match local key at ${DEPLOY_KEY_PATH}, deleting id ${stale_id}"
    gh repo deploy-key delete "${stale_id}" --repo "${REPO_SLUG}"
  done < <(deploy_key_title_ids)
  log "registering read-only deploy key on ${REPO_SLUG}"
  # gh deploy keys are read-only by default (write access is opt-in via -w/--allow-write)
  gh repo deploy-key add "${DEPLOY_KEY_PATH}.pub" --repo "${REPO_SLUG}" --title kind-lab-argocd
}

apply_repo_creds() {
  log "applying ArgoCD repo-creds secret for ${REPO_SSH_URL}"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kind-lab-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: ${REPO_SSH_URL}
  sshPrivateKey: |
$(sed 's/^/    /' "${DEPLOY_KEY_PATH}")
EOF
}

applications_healthy() {
  local not_synced
  not_synced=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}{"\n"}{end}' \
    | grep -vc '^Synced$' || true)
  [ "${not_synced}" -eq 0 ]
}

warn_if_local_head_diverged_from_origin_main() {
  local repo_dir local_head origin_main
  repo_dir="${SCRIPT_DIR}/.."
  local_head="$(git -C "${repo_dir}" rev-parse HEAD 2>/dev/null)" || return 0
  origin_main="$(git -C "${repo_dir}" rev-parse origin/main 2>/dev/null)" || {
    warn "no local origin/main ref found (nothing pushed yet?); ArgoCD will reconcile from whatever is on origin/main once it exists"
    return 0
  }
  if [ "${local_head}" != "${origin_main}" ]; then
    warn "local HEAD (${local_head}) differs from origin/main (${origin_main})"
    warn "the argocd Application will reconcile helm/argocd from origin/main via Git, NOT from this local checkout, once ArgoCD is up — local edits or an unpushed HEAD may appear to have no effect (or be self-healed away)"
  fi
  if ! git -C "${repo_dir}" diff --quiet 2>/dev/null || ! git -C "${repo_dir}" diff --cached --quiet 2>/dev/null; then
    warn "local working tree has uncommitted changes; ArgoCD will not see them since it reconciles from origin/main via Git"
  fi
}

main() {
  require_cmd helm kubectl ssh-keygen gh sed

  warn_if_local_head_diverged_from_origin_main
  install_argocd
  ensure_deploy_key
  register_deploy_key
  apply_repo_creds

  log "applying root App-of-Apps"
  kubectl apply -f "${SCRIPT_DIR}/../gitops/root-app.yaml"

  wait_for "all ArgoCD Applications Synced" 300 applications_healthy
  log "ArgoCD bootstrap complete"
}

main "$@"
