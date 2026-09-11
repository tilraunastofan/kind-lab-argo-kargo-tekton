#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

STEP_CONFIG_DIR="${HOME}/.step/config"
STEP_CERTS_DIR="${HOME}/.step/certs"
STEP_SECRETS_DIR="${HOME}/.step/secrets"
STEPCA_PLIST="${HOME}/Library/LaunchAgents/com.smallstep.step-ca.plist"

step_ca_hostname() {
  scutil --get LocalHostName 2>/dev/null || hostname -s
}

step_ca_initialized() {
  [ -f "${STEP_CONFIG_DIR}/ca.json" ] && [ -f "${STEP_CONFIG_DIR}/defaults.json" ]
}

step_ca_healthy() {
  curl -sk --max-time 3 "https://localhost:${STEPCA_PORT}/health" 2>/dev/null | grep -q '"status":"ok"'
}

launchd_loaded() {
  launchctl list 2>/dev/null | grep -q "com.smallstep.step-ca"
}

root_trusted() {
  [ -f "${STEP_CERTS_DIR}/root_ca.crt" ] || return 1
  local fp
  fp=$(openssl x509 -in "${STEP_CERTS_DIR}/root_ca.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')
  security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | tr -d ' \n' | grep -qi "${fp}"
}

clean_partial_state() {
  local step_dir="${HOME}/.step"
  # step_ca_initialized() has already returned false at this point, so there is no
  # complete CA identity to protect. But ~/.step may still exist non-empty from a
  # prior interrupted/failed run (e.g. partially-written secrets/ or config/), and
  # `step ca init` refuses to run non-interactively against a non-empty ~/.step.
  # Move any such partial state aside so init can proceed cleanly.
  if [ -d "${step_dir}" ] && [ -n "$(ls -A "${step_dir}" 2>/dev/null)" ]; then
    local backup="${step_dir}.partial-$(date +%Y%m%d%H%M%S)"
    warn "found incomplete ~/.step state from a prior run; moving it aside to ${backup} before initializing"
    mv "${step_dir}" "${backup}"
  fi
}

init_pki() {
  log "step-ca PKI not found, initializing a fresh passwordless root+intermediate"
  clean_partial_state
  local pw_file
  pw_file=$(mktemp)
  printf 'lab-temp-pw\n' > "${pw_file}"
  local host
  host=$(step_ca_hostname)

  step ca init \
    --deployment-type standalone \
    --name "kind-lab-StepCA" \
    --dns "${host}.local,${host},localhost,127.0.0.1" \
    --address ":${STEPCA_PORT}" \
    --provisioner "lab@localhost" \
    --provisioner-password-file "${pw_file}" \
    --password-file "${pw_file}" \
    --acme

  local key
  for key in root_ca_key intermediate_ca_key; do
    openssl ec -passin "file:${pw_file}" -in "${STEP_SECRETS_DIR}/${key}" -out "${STEP_SECRETS_DIR}/${key}.plain"
    mv "${STEP_SECRETS_DIR}/${key}.plain" "${STEP_SECRETS_DIR}/${key}"
    chmod 600 "${STEP_SECRETS_DIR}/${key}"
  done

  shred -u "${pw_file}" 2>/dev/null || rm -f "${pw_file}"
}

install_launchd_agent() {
  log "installing step-ca launchd agent"
  mkdir -p "$(dirname "${STEPCA_PLIST}")" "${HOME}/Library/Logs"
  local bin
  bin=$(command -v step-ca)
  cat > "${STEPCA_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.smallstep.step-ca</string>
	<key>ProgramArguments</key>
	<array>
		<string>${bin}</string>
		<string>${STEP_CONFIG_DIR}/ca.json</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${HOME}/Library/Logs/step-ca.log</string>
	<key>StandardErrorPath</key>
	<string>${HOME}/Library/Logs/step-ca.err.log</string>
</dict>
</plist>
PLIST
  launchctl unload "${STEPCA_PLIST}" 2>/dev/null || true
  launchctl load "${STEPCA_PLIST}"
}

main() {
  require_cmd step step-ca openssl security launchctl curl scutil

  if step_ca_initialized && launchd_loaded && step_ca_healthy && root_trusted; then
    log "step-ca already fully bootstrapped, skipping"
    return 0
  fi

  step_ca_initialized || init_pki
  launchd_loaded || install_launchd_agent

  wait_for "step-ca health check" 30 step_ca_healthy

  if ! root_trusted; then
    warn "the root CA is not yet trusted by the macOS System keychain"
    echo
    echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${STEP_CERTS_DIR}/root_ca.crt"
    echo
    die "run the command above, then re-run bootstrap.sh"
  fi

  log "step-ca bootstrap complete"
}

main "$@"
