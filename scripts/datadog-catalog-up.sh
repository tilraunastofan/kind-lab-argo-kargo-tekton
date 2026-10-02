#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Registers (or updates) every service definition under
# datadog/service-catalog/*.json in Datadog's Software Catalog, via the
# catalog API on the EU site. The API needs BOTH keys in the environment:
# DATADOG_API_KEY (already used by the cluster) and DATADOG_APP_KEY, an
# Application Key (Organization Settings > Application Keys) whose owner may
# write to the Software Catalog. Neither is committed to Git. Idempotent:
# re-running updates the existing entity.
#
# Not part of bootstrap.sh: Datadog normally auto-creates catalog entries
# from APM traces, and this only matters when that has not happened (or to
# attach metadata such as links and code locations).

# Global (not `local` in main): the EXIT trap runs after main returns, when a
# local would already be unset and `set -u` would abort on it.
body=""

main() {
  require_cmd curl
  [ -n "${DATADOG_API_KEY:-}" ] || die "DATADOG_API_KEY is not set"
  [ -n "${DATADOG_APP_KEY:-}" ] || die "DATADOG_APP_KEY is not set (create an Application Key in Datadog)"

  local f code
  body="$(mktemp)"
  trap 'rm -f "${body}"' EXIT
  for f in "${SCRIPT_DIR}"/../datadog/service-catalog/*.json; do
    log "registering $(basename "${f}")"
    code="$(curl -sS -o "${body}" -w '%{http_code}' -X POST "https://api.datadoghq.eu/api/v2/catalog/entity" \
      -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
      -H "Content-Type: application/json" --data-binary "@${f}")"
    case "${code}" in
      2??) log "ok (HTTP ${code})" ;;
      *) cat "${body}" >&2; die "Datadog returned HTTP ${code} for ${f}" ;;
    esac
  done
}

main "$@"
