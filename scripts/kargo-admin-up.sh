#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates Kargo's admin-account Secret (kargo-admin, in the kargo
# namespace) so its API server has something to authenticate against.
# Kargo's own Helm chart (unlike every other chart this repo installs)
# does not auto-generate this — see gitops/apps/kargo.yaml's
# api.secret.name override, which points the chart at this exact Secret
# instead of requiring a password hash inlined into Git-committed values.
#
# The password is a lab credential stored in ~/.tokens as
# KARGO_ADMIN_PASSWORD (generated once by ensure_token, never committed), so
# it can always be read back: `source ~/.tokens; echo "$KARGO_ADMIN_PASSWORD"`.
# The Secret is (re)created whenever it is missing OR its hash doesn't match
# that password, so a rebuilt cluster and a forgotten password both heal by
# re-running this script. An existing token signing key is kept, so a
# password re-sync doesn't invalidate logged-in sessions.
#
# htpasswd -bnBC 10 "" <password> is Kargo's own documented method for
# generating this exact bcrypt hash format (confirmed against Kargo's
# quickstart docs) — the leading empty username ("") and -n (no colon
# prefix written to a file) just make htpasswd emit ":<hash>" to stdout,
# which the `cut` below strips down to the hash alone.

password_matches_secret() {
  local hash tmp ok=1
  hash="$(kubectl -n kargo get secret kargo-admin -o jsonpath='{.data.ADMIN_ACCOUNT_PASSWORD_HASH}' 2>/dev/null | base64 -d)" || return 1
  [ -n "${hash}" ] || return 1
  tmp="$(mktemp)"
  printf 'admin:%s\n' "${hash}" > "${tmp}"
  htpasswd -vb "${tmp}" admin "${KARGO_ADMIN_PASSWORD}" >/dev/null 2>&1 && ok=0
  rm -f "${tmp}"
  return "${ok}"
}

main() {
  require_cmd kubectl htpasswd openssl base64

  ensure_token KARGO_ADMIN_PASSWORD

  log "ensuring kargo namespace exists"
  kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f -

  if password_matches_secret; then
    log "kargo-admin Secret already matches KARGO_ADMIN_PASSWORD, leaving it as-is"
    return 0
  fi

  local password_hash token_signing_key
  password_hash="$(htpasswd -bnBC 10 "" "${KARGO_ADMIN_PASSWORD}" | cut -d: -f2)"
  token_signing_key="$(kubectl -n kargo get secret kargo-admin -o jsonpath='{.data.ADMIN_ACCOUNT_TOKEN_SIGNING_KEY}' 2>/dev/null | base64 -d || true)"
  [ -n "${token_signing_key}" ] || token_signing_key="$(openssl rand -base64 29 | tr -d '=+/')"

  kubectl -n kargo create secret generic kargo-admin \
    --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="${password_hash}" \
    --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="${token_signing_key}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "kargo-admin Secret synced to KARGO_ADMIN_PASSWORD — show it with: source ~/.tokens; echo \"\$KARGO_ADMIN_PASSWORD\""
  warn "if kargo-api is already running, restart it to pick up the new password: kubectl -n kargo rollout restart deploy kargo-api"
}

main "$@"
