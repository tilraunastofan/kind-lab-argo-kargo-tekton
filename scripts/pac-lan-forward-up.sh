#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Sets up (idempotently) a root LaunchDaemon that TCP-forwards this Mac's
# real LAN-facing IP, port 443, straight through to ingress-nginx's
# cloud-provider-kind LoadBalancer IP, port 443 — plain socat TCP
# forwarding, no TLS termination/re-termination here.
#
# Why this exists: cloud-provider-kind's assigned LoadBalancer IP (see
# `kubectl -n ingress-nginx get svc`) is bound to this Mac's loopback
# interface (lo0), so *.tekton-lab.test only resolves/routes correctly for
# processes running ON this Mac (via the /etc/resolver/tekton-lab.test entry).
# Anything elsewhere on the LAN — e.g. a self-hosted Forgejo instance on a
# Raspberry Pi delivering webhooks to https://pipelines-as-code.tekton-lab.test —
# can't reach it at all. This forwarder, plus a DNS/hosts override on the
# remote side pointing the hostname at this Mac's real LAN IP, closes that
# gap without touching TLS: the SNI (pipelines-as-code.tekton-lab.test) and the
# cert handshake both still terminate at the in-cluster ingress-nginx
# controller, so whatever's on the other end of the LAN gets the same
# trusted cert it would if it could reach ingress-nginx directly.
#
# Both ingress-nginx's LoadBalancer IP and this Mac's LAN IP can change
# (cluster restarts reassign the former; DHCP or network changes can
# reassign the latter — same reasoning as STEPCA_HOST in
# scripts/issuer-up.sh), so both are looked up live every run rather than
# hardcoded, and the LaunchDaemon plist is rewritten + reloaded whenever
# either value has drifted since the last run.
#
# Modeled on the cloud-provider-kind root LaunchDaemon this repo already
# depends on (see CPK_LAUNCHD_LABEL in scripts/cluster-up.sh) — same
# pattern: a long-lived host-level process that needs to survive reboots
# and outlive any one bootstrap session, so it's a LaunchDaemon rather
# than something started from a shell.
#
# NOT wired into bootstrap.sh — this is new host-level infrastructure for
# an external (Pi-hosted Forgejo) webhook-delivery integration, not yet
# part of the core cluster bring-up path. Run it standalone, by hand.

PAC_HOSTNAME="pipelines-as-code.tekton-lab.test"
FORWARD_PORT="443"
PLIST_LABEL="com.kind-lab.pac-lan-forward"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_LABEL}.plist"
FORWARDER_OUT_LOG="/var/log/${PLIST_LABEL}.out.log"
FORWARDER_ERR_LOG="/var/log/${PLIST_LABEL}.err.log"

ensure_socat() {
  if command -v socat >/dev/null 2>&1; then
    log "socat already installed ($(command -v socat))"
    return
  fi
  require_cmd brew
  log "installing socat via Homebrew"
  brew install socat
}

# current_ingress_ip: ingress-nginx's live cloud-provider-kind
# LoadBalancer IP (can change across cluster restarts). Only one
# LoadBalancer Service exists in the ingress-nginx namespace, so no
# name-filtering awk trick is needed here (the old lab-gateway namespace
# could, in principle, hold more than one).
current_ingress_ip() {
  kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

# current_lan_ip: this Mac's real LAN-facing IPv4 address (the primary
# active interface's inet address — typically en0, but this doesn't
# assume the interface name, since that can differ per Mac/dock setup).
current_lan_ip() {
  route get 1.1.1.1 2>/dev/null | awk '/interface: /{print $2}' | while read -r iface; do
    ipconfig getifaddr "${iface}" 2>/dev/null
  done
}

write_plist() {
  local ingress_ip="$1" lan_ip="$2" tmp_plist
  tmp_plist="$(mktemp)"
  cat >"${tmp_plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(command -v socat)</string>
    <string>TCP-LISTEN:${FORWARD_PORT},fork,reuseaddr,bind=${lan_ip}</string>
    <string>TCP:${ingress_ip}:${FORWARD_PORT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${FORWARDER_OUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${FORWARDER_ERR_LOG}</string>
</dict>
</plist>
EOF

  if [ -f "${PLIST_PATH}" ] && sudo diff -q "${tmp_plist}" "${PLIST_PATH}" >/dev/null 2>&1; then
    log "plist at ${PLIST_PATH} already up to date (bind=${lan_ip} -> ${ingress_ip}:${FORWARD_PORT})"
    rm -f "${tmp_plist}"
    return 1 # no change; caller shouldn't force a reload
  fi

  log "writing ${PLIST_PATH} (bind=${lan_ip} -> ${ingress_ip}:${FORWARD_PORT})"
  # NOTE: this function is called as the condition of an `if`, which
  # disables `set -e` for everything inside it (a well-known bash
  # gotcha) — so each sudo step is checked explicitly with `|| die`
  # rather than relying on errexit to stop the script on failure.
  sudo cp "${tmp_plist}" "${PLIST_PATH}" || { rm -f "${tmp_plist}"; die "failed to write ${PLIST_PATH} (needs sudo)"; }
  sudo chown root:wheel "${PLIST_PATH}" || die "failed to chown ${PLIST_PATH}"
  sudo chmod 644 "${PLIST_PATH}" || die "failed to chmod ${PLIST_PATH}"
  rm -f "${tmp_plist}"
  return 0 # changed; caller should (re)load
}

load_daemon() {
  local changed="$1"
  local target="system/${PLIST_LABEL}"

  # bootout is a no-op (harmless failure) if it wasn't loaded yet.
  if [ "${changed}" = "0" ]; then
    if sudo launchctl print "${target}" >/dev/null 2>&1; then
      log "LaunchDaemon ${PLIST_LABEL} already loaded and config unchanged; leaving it running"
      return
    fi
    log "LaunchDaemon ${PLIST_LABEL} not currently loaded; bootstrapping"
  else
    log "config changed; reloading LaunchDaemon ${PLIST_LABEL}"
    sudo launchctl bootout system "${target}" >/dev/null 2>&1 || true
  fi

  sudo launchctl bootstrap system "${PLIST_PATH}" || die "failed to bootstrap LaunchDaemon ${PLIST_LABEL} (needs sudo)"
  sudo launchctl kickstart -k "${target}" || die "failed to kickstart LaunchDaemon ${PLIST_LABEL}"
}

verify_listening() {
  local lan_ip="$1"
  log "verifying the forwarder is listening on ${lan_ip}:${FORWARD_PORT}"
  local elapsed=0 timeout=15
  until lsof -nP -iTCP:"${FORWARD_PORT}" -sTCP:LISTEN 2>/dev/null | grep -q "${lan_ip}:${FORWARD_PORT}\|\\*:${FORWARD_PORT}"; do
    if [ "${elapsed}" -ge "${timeout}" ]; then
      warn "could not confirm a listener on ${lan_ip}:${FORWARD_PORT} within ${timeout}s"
      warn "check ${FORWARDER_ERR_LOG} and: sudo launchctl print system/${PLIST_LABEL}"
      die "forwarder verification failed"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  log "confirmed: socat listening on ${lan_ip}:${FORWARD_PORT}"

  log "smoke-testing the forward with curl --resolve"
  if curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      --resolve "${PAC_HOSTNAME}:${FORWARD_PORT}:${lan_ip}" \
      "https://${PAC_HOSTNAME}" | grep -qE '^[0-9]{3}$'; then
    log "curl --resolve ${PAC_HOSTNAME}:${FORWARD_PORT}:${lan_ip} https://${PAC_HOSTNAME} reached ingress-nginx through the forwarder"
  else
    warn "curl smoke test through the forwarder did not return a clean HTTP status; check manually"
  fi
}

main() {
  require_cmd kubectl curl launchctl lsof

  ensure_socat

  local ingress_ip lan_ip changed
  ingress_ip="$(current_ingress_ip)"
  [ -n "${ingress_ip}" ] || die "could not determine ingress-nginx's LoadBalancer IP (kubectl -n ingress-nginx get svc) — is the cluster up?"

  lan_ip="$(current_lan_ip)"
  [ -n "${lan_ip}" ] || die "could not determine this Mac's LAN IP (route get 1.1.1.1 / ipconfig getifaddr) — check network connectivity"

  log "ingress-nginx LoadBalancer IP: ${ingress_ip}"
  log "Mac LAN IP: ${lan_ip}"

  if write_plist "${ingress_ip}" "${lan_ip}"; then
    changed=1
  else
    changed=0
  fi

  load_daemon "${changed}"
  verify_listening "${lan_ip}"

  log "pac-lan-forward ready: ${lan_ip}:${FORWARD_PORT} -> ${ingress_ip}:${FORWARD_PORT} (plain TCP, TLS untouched)"
  log "remember: this LaunchDaemon persists across reboots on its own; re-run this script any time ingress-nginx's LoadBalancer IP or this Mac's LAN IP changes"
}

main "$@"
