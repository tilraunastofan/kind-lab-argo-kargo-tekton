#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Makes ArgoCD's built-in `admin` password a known lab credential: stored in
# ~/.tokens as ARGOCD_ADMIN_PASSWORD (generated once by ensure_token, never
# committed), then written into ArgoCD's argocd-secret as a bcrypt hash.
# Re-run any time: it only touches the Secret when the stored password and
# the live hash differ, so a rebuilt cluster (fresh random initial password)
# and a changed/forgotten password both heal. Show it with:
#   source ~/.tokens; echo "$ARGOCD_ADMIN_PASSWORD"
#
# Uses ArgoCD's documented manual-reset method: set admin.password (bcrypt,
# $2a$ prefix) and admin.passwordMtime in argocd-secret; the server picks it
# up without a restart. The one-shot argocd-initial-admin-secret is deleted
# afterwards, as ArgoCD's docs recommend, since it would only hold a stale
# password.

password_matches_secret() {
  local hash tmp ok=1
  hash="$(kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d)" || return 1
  [ -n "${hash}" ] || return 1
  tmp="$(mktemp)"
  printf 'admin:%s\n' "${hash}" > "${tmp}"
  htpasswd -vb "${tmp}" admin "${ARGOCD_ADMIN_PASSWORD}" >/dev/null 2>&1 && ok=0
  rm -f "${tmp}"
  return "${ok}"
}

main() {
  require_cmd kubectl htpasswd base64

  ensure_token ARGOCD_ADMIN_PASSWORD

  kubectl -n argocd get secret argocd-secret >/dev/null 2>&1 \
    || die "argocd-secret not found in namespace argocd — run this after ArgoCD is installed (argocd-up.sh)"

  if password_matches_secret; then
    log "ArgoCD admin password already matches ARGOCD_ADMIN_PASSWORD, leaving it as-is"
  else
    local hash
    hash="$(htpasswd -bnBC 10 "" "${ARGOCD_ADMIN_PASSWORD}" | tr -d ':\n' | sed 's/^\$2y/$2a/')"
    kubectl -n argocd patch secret argocd-secret --type merge -p \
      "{\"stringData\":{\"admin.password\":\"${hash}\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}" >/dev/null
    log "ArgoCD admin password set from ARGOCD_ADMIN_PASSWORD — show it with: source ~/.tokens; echo \"\$ARGOCD_ADMIN_PASSWORD\""
  fi

  kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
}

main "$@"
