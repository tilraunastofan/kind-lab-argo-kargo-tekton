#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CPK_PLIST_SYSTEM="/Library/LaunchDaemons/com.kind.cloud-provider-kind.plist"

cpk_installed() {
  command -v cloud-provider-kind >/dev/null 2>&1
}

cpk_running() {
  pgrep -x cloud-provider-kind >/dev/null 2>&1
}

plist_installed() {
  [ -f "${CPK_PLIST_SYSTEM}" ]
}

install_binary() {
  log "installing cloud-provider-kind via go install"
  require_cmd go
  go install sigs.k8s.io/cloud-provider-kind@latest
}

find_docker_cli() {
  local candidates=(
    "$(command -v docker 2>/dev/null)"
    "${HOME}/.orbstack/bin/docker"
    "/usr/local/bin/docker"
    "/opt/homebrew/bin/docker"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -n "${c}" ] && [ -x "${c}" ] && { echo "${c}"; return 0; }
  done
  return 1
}

docker_host() {
  local docker_bin host
  docker_bin="$(find_docker_cli)" || { echo "unix:///var/run/docker.sock"; return; }
  host=$("${docker_bin}" context inspect "$("${docker_bin}" context show 2>/dev/null)" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
  echo "${host:-unix:///var/run/docker.sock}"
}

print_sudo_instructions() {
  local bin tmp_plist dh docker_bin docker_dir daemon_path
  bin="$(command -v cloud-provider-kind || echo "${HOME}/go/bin/cloud-provider-kind")"
  dh="$(docker_host)"
  docker_bin="$(find_docker_cli || true)"
  docker_dir="$([ -n "${docker_bin}" ] && dirname "${docker_bin}" || echo "")"
  daemon_path="${docker_dir:+${docker_dir}:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  tmp_plist="$(mktemp /tmp/com.kind.cloud-provider-kind.XXXX.plist)"
  cat > "${tmp_plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.kind.cloud-provider-kind</string>
	<key>ProgramArguments</key>
	<array>
		<string>${bin}</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>DOCKER_HOST</key>
		<string>${dh}</string>
		<key>PATH</key>
		<string>${daemon_path}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/var/log/cloud-provider-kind.log</string>
	<key>StandardErrorPath</key>
	<string>/var/log/cloud-provider-kind.err.log</string>
</dict>
</plist>
PLIST

  warn "cloud-provider-kind needs a root LaunchDaemon (macOS requires elevated privileges for its networking setup)"
  echo
  echo "  sudo cp ${tmp_plist} ${CPK_PLIST_SYSTEM}"
  echo "  sudo launchctl bootout system/com.kind.cloud-provider-kind 2>/dev/null; sudo launchctl bootstrap system ${CPK_PLIST_SYSTEM}"
  echo
  die "run the commands above, then re-run bootstrap.sh"
}

main() {
  if cpk_installed && plist_installed && cpk_running; then
    log "cloud-provider-kind already bootstrapped, skipping"
    return 0
  fi

  cpk_installed || install_binary

  if ! plist_installed || ! cpk_running; then
    print_sudo_instructions
  fi

  log "cloud-provider-kind bootstrap complete"
}

main "$@"
