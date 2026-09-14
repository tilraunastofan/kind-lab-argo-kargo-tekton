#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_HOST_SSH="cm4.local"
MAC_LAN_IP_CACHE=""

# Idempotently applies three fixes to the Forgejo instance on the
# Raspberry Pi that Task 6's end-to-end verification found necessary —
# none of these are configurable from Forgejo's own repo/webhook API, so
# unlike scripts/forgejo-repo-up.sh (which only talks to the Forgejo API)
# this one needs SSH+docker access to the host itself (the user has
# granted passwordless sudo on cm4.local for exactly this purpose):
#
#   1. Trust the step-ca root CA inside the Forgejo container, so its
#      outbound webhook HTTP client can verify pipelines-as-code.tekton-lab.test's
#      cert. Lost on container recreation (lives in the container's own
#      filesystem, not its data volume) — safe to re-run any time.
#   2. Add a /etc/hosts entry inside the Forgejo container resolving
#      pipelines-as-code.tekton-lab.test to this Mac's real LAN IP. Reachable
#      directly: kind's own port-mapping (cluster/kind-config.yaml) binds
#      ingress-nginx's host ports 80/443 to every interface on this Mac,
#      not just loopback, so no separate forwarder is needed for LAN
#      devices like this one. Also lost on container recreation.
#   3. Ensure app.ini's [webhook] ALLOWED_HOST_LIST includes this LAN's
#      subnet and the hostname — Forgejo's own SSRF-protection webhook
#      target validator otherwise silently drops (not even logs as
#      "delivered") every attempt to reach a private-IP webhook target.
#      This lives in app.ini, inside Forgejo's persistent /data volume, so
#      it's NOT lost on container recreation — this step is a no-op after
#      the first run unless app.ini is reset.
#
# Fixes 1 and 2 need to be re-run after every Forgejo container
# recreation (not a plain restart) — this script is idempotent and safe
# to re-run any time to check/restore all three.

current_lan_ip() {
  route get 1.1.1.1 2>/dev/null | awk '/interface: /{print $2}' | while read -r iface; do
    ipconfig getifaddr "${iface}" 2>/dev/null
  done
}

main() {
  require_cmd ssh scp

  log "checking step-ca root CA trust inside the forgejo container"
  if ssh "${FORGEJO_HOST_SSH}" "docker exec forgejo test -f /usr/local/share/ca-certificates/stepca-root.crt" 2>/dev/null; then
    log "step-ca root already trusted, skipping"
  else
    log "installing step-ca root CA into the forgejo container"
    scp "${HOME}/.step/certs/root_ca.crt" "${FORGEJO_HOST_SSH}:/tmp/stepca-root.crt" >/dev/null
    ssh "${FORGEJO_HOST_SSH}" "docker cp /tmp/stepca-root.crt forgejo:/usr/local/share/ca-certificates/stepca-root.crt && docker exec -u root forgejo sh -c 'chmod 644 /usr/local/share/ca-certificates/stepca-root.crt && update-ca-certificates'"
  fi

  MAC_LAN_IP_CACHE="$(current_lan_ip)"
  [ -n "${MAC_LAN_IP_CACHE}" ] || die "could not determine this Mac's LAN IP"

  log "checking pipelines-as-code.tekton-lab.test DNS override inside the forgejo container"
  if ssh "${FORGEJO_HOST_SSH}" "docker exec forgejo grep -q pipelines-as-code.tekton-lab.test /etc/hosts" 2>/dev/null; then
    log "hosts override already present, skipping"
  else
    log "adding pipelines-as-code.tekton-lab.test -> ${MAC_LAN_IP_CACHE} to the forgejo container's /etc/hosts"
    ssh "${FORGEJO_HOST_SSH}" "docker exec -u root forgejo sh -c 'echo \"${MAC_LAN_IP_CACHE} pipelines-as-code.tekton-lab.test\" >> /etc/hosts'"
  fi

  log "checking webhook.ALLOWED_HOST_LIST in Forgejo's app.ini"
  if ssh "${FORGEJO_HOST_SSH}" "docker exec forgejo grep -q ALLOWED_HOST_LIST /data/gitea/conf/app.ini" 2>/dev/null; then
    log "ALLOWED_HOST_LIST already configured, skipping (edit app.ini by hand and restart forgejo if the LAN subnet changes)"
  else
    log "adding [webhook] ALLOWED_HOST_LIST to app.ini and restarting forgejo"
    ssh "${FORGEJO_HOST_SSH}" "docker exec forgejo sh -c 'printf \"\\n[webhook]\\nALLOWED_HOST_LIST = 192.168.1.0/24,pipelines-as-code.tekton-lab.test\\n\" >> /data/gitea/conf/app.ini' && docker restart forgejo"
    warn "forgejo was restarted — if it publishes a dynamic Docker port (docker inspect forgejo), your reverse proxy in front of git.local may need its upstream port updated"
  fi

  log "pac-forgejo-trust-up complete"
}

main "$@"
