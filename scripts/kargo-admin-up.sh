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
# Only generates a new random password the FIRST time (i.e. if this Secret
# doesn't already exist) — a full `cluster:down`+`cluster:up` always
# destroys and recreates the whole cluster anyway, so there's nothing to
# preserve across a cold rebuild; but re-running this script against a
# cluster that's already up (e.g. bootstrap.sh re-run after a partial
# failure) must NOT invalidate a password the user may have already
# copied down.
#
# htpasswd -bnBC 10 "" <password> is Kargo's own documented method for
# generating this exact bcrypt hash format (confirmed against Kargo's
# quickstart docs) — the leading empty username ("") and -n (no colon
# prefix written to a file) just make htpasswd emit ":<hash>" to stdout,
# which the `cut` below strips down to the hash alone.

main() {
  require_cmd kubectl htpasswd openssl

  log "ensuring kargo namespace exists"
  kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f -

  if kubectl -n kargo get secret kargo-admin >/dev/null 2>&1; then
    log "kargo-admin Secret already exists in kargo, leaving it as-is"
    return 0
  fi

  local password password_hash token_signing_key
  password="$(openssl rand -base64 18 | tr -d '=+/')"
  password_hash="$(htpasswd -bnBC 10 "" "${password}" | cut -d: -f2)"
  token_signing_key="$(openssl rand -base64 29 | tr -d '=+/')"

  kubectl -n kargo create secret generic kargo-admin \
    --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="${password_hash}" \
    --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="${token_signing_key}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "kargo-admin Secret created — Kargo admin password (save this now, it will not be shown again): ${password}"
}

main "$@"
