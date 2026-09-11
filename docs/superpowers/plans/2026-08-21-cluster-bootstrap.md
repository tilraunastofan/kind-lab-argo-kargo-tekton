# Cluster Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `task cluster:up` into a single idempotent command that bootstraps step-ca and cloud-provider-kind on the host, creates a 3-node kind cluster with Cilium as CNI + Gateway API implementation, installs cert-manager wired to step-ca's ACME provisioner, sets up in-cluster DNS for `*.lab.test`, and proves the whole chain works via a throwaway smoke-test app served over trusted HTTPS at `https://smoke.lab.test`.

**Architecture:** A thin `bootstrap.sh` entrypoint calls a sequence of small, idempotent bash scripts under `scripts/`, each responsible for one piece (step-ca, cloud-provider-kind, kind cluster, Cilium, cert-manager, shared Gateway, DNS, ACME issuer, smoke test). Kubernetes-facing manifests live under `helm/`, applied via `kubectl apply` (plain manifests) or `helm upgrade --install` (charts). All scripts source a shared `scripts/lib.sh` for logging, prerequisite checks, and a poll-based `wait_for` helper.

**Tech Stack:** bash, `kind`, `helm`, `kubectl`, `step`/`step-ca`, `cloud-provider-kind` (Go), Cilium (Helm chart), cert-manager (Helm chart), Gateway API (upstream CRDs), `dnsmasq`, Task (`Taskfile.yaml`, Task v3 schema).

## Global Constraints

- Cluster name: `kind-lab` (kind context becomes `kind-kind-lab`).
- Lab domain: `lab.test`, smoke-test hostname: `smoke.lab.test`.
- step-ca listens on `:9443` (not 443 — that's taken by the host's Caddy instance). ACME directory: `https://<hostname>.local:9443/acme/acme/directory`.
- No kind `extraPortMappings` — all traffic goes through routable LoadBalancer/node IPs (OrbStack), never through host-mapped ports.
- Every script: `set -euo pipefail`, sources `scripts/lib.sh`, is safe to re-run (idempotent).
- Commit messages must follow Conventional Commits (`type: subject`) — this repo's commit-msg hook rejects anything else. Use `feat:`, `fix:`, `docs:`, or `chore:` as appropriate.
- Gateway API version: `v1.1.0` **experimental channel** (corrected during Task 5 — see below). Cilium chart version: `1.16.5`. cert-manager chart version: `v1.16.2`.

---

## Task 1: Shared shell library + Taskfile skeleton

**Files:**
- Create: `scripts/lib.sh`
- Create: `Taskfile.yaml`
- Create: `bootstrap.sh`

**Interfaces:**
- Produces: `log(msg)`, `warn(msg)`, `die(msg)` (print + exit 1), `require_cmd(cmd...)` (exits via `die` if any command is missing), `wait_for(description, timeout_seconds, check_fn)` (polls `check_fn` every 3s, calls `die` on timeout) — every later task's scripts source this file and use these functions.
- Consumes: nothing (first task).

- [ ] **Step 1: Write `scripts/lib.sh`**

```bash
#!/usr/bin/env bash

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: ${cmd}"
  done
}

# wait_for <description> <timeout_seconds> <check_fn> [args...]
wait_for() {
  local desc="$1" timeout="$2"
  shift 2
  local elapsed=0
  until "$@" >/dev/null 2>&1; do
    if [ "${elapsed}" -ge "${timeout}" ]; then
      die "timed out after ${timeout}s waiting for: ${desc}"
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  log "${desc}: ready"
}

CLUSTER_NAME="kind-lab"
LAB_DOMAIN="lab.test"
STEPCA_PORT="9443"
```

- [ ] **Step 2: Make it executable and verify it loads cleanly**

Run: `chmod +x scripts/lib.sh && bash -c 'source scripts/lib.sh && require_cmd bash && log "lib.sh OK"'`
Expected: prints `==> lib.sh OK` with no errors.

- [ ] **Step 3: Write `bootstrap.sh` (entrypoint, calls nothing yet except prereqs)**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst

  log "prerequisites OK"
  log "kind-lab bootstrap complete"
}

main "$@"
```

- [ ] **Step 4: Write `Taskfile.yaml`**

```yaml
version: "3"

tasks:
  cluster:up:
    desc: Bootstrap the full kind-lab cluster (step-ca, cloud-provider-kind, kind, Cilium, cert-manager, DNS, smoke test)
    cmds:
      - ./bootstrap.sh

  cluster:down:
    desc: Tear down the kind-lab cluster
    cmds:
      - ./scripts/cluster-down.sh

  cluster:status:
    desc: Quick health check of the cluster
    cmds:
      - ./scripts/cluster-status.sh

  smoke:test:
    desc: Re-run just the smoke-test verification
    cmds:
      - ./scripts/smoke-test.sh
```

- [ ] **Step 5: Verify prereq check works**

Run: `chmod +x bootstrap.sh && ./bootstrap.sh`
Expected: either `kind-lab bootstrap complete` (if all tools are installed) or a `die` message naming exactly one missing tool. Install any missing tool it names (`brew install kind kubernetes-cli helm`, `go` via `brew install go`) and re-run until it passes.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh Taskfile.yaml bootstrap.sh
git commit -m "feat: add bootstrap entrypoint and shared shell helpers"
```

---

## Task 2: step-ca host bootstrap (idempotent)

**Files:**
- Create: `scripts/stepca-bootstrap.sh`
- Modify: `bootstrap.sh` (call it)

**Interfaces:**
- Consumes: `log`, `warn`, `die`, `require_cmd`, `wait_for`, `STEPCA_PORT` from `scripts/lib.sh`.
- Produces: nothing consumed programmatically by later tasks (later tasks read `~/.step/certs/root_ca.crt` and `~/.step/config/*.json` directly from disk, and assume port `${STEPCA_PORT}` — no shared variable needed since it's a constant in `lib.sh`).

- [ ] **Step 1: Write `scripts/stepca-bootstrap.sh`**

```bash
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

init_pki() {
  log "step-ca PKI not found, initializing a fresh passwordless root+intermediate"
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
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/stepca-bootstrap.sh`

- [ ] **Step 3: Run it standalone and verify no-op on this Mac**

Run: `./scripts/stepca-bootstrap.sh`
Expected: `step-ca already fully bootstrapped, skipping` (this Mac was already set up earlier in this project) and exit code 0.

- [ ] **Step 4: Verify a true first-time run would work (dry check, do not actually wipe `~/.step`)**

Run: `bash -n scripts/stepca-bootstrap.sh`
Expected: no syntax errors (exit 0, no output). Do not delete `~/.step` to test the init path — this machine's step-ca is real infrastructure other tools depend on.

- [ ] **Step 5: Wire it into `bootstrap.sh`**

Edit `bootstrap.sh`, replacing the `main()` body:

```bash
main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst

  "${SCRIPT_DIR}/stepca-bootstrap.sh"

  log "kind-lab bootstrap complete"
}
```

- [ ] **Step 6: Run full bootstrap.sh and verify it still passes through**

Run: `./bootstrap.sh`
Expected: prints the step-ca no-op message, then `kind-lab bootstrap complete`.

- [ ] **Step 7: Commit**

```bash
git add scripts/stepca-bootstrap.sh bootstrap.sh
git commit -m "feat: add idempotent step-ca host bootstrap"
```

---

## Task 3: cloud-provider-kind host bootstrap (idempotent)

**Files:**
- Create: `scripts/cloudprovider-bootstrap.sh`
- Modify: `bootstrap.sh` (call it)

**Interfaces:**
- Consumes: `log`, `warn`, `die`, `require_cmd`, `wait_for` from `lib.sh`.
- Produces: nothing programmatic — later tasks just assume a `LoadBalancer` Service will get an IP assigned because this process is running.

**Correction (discovered during implementation attempt):** `cloud-provider-kind` requires root on macOS — running it unprivileged fails immediately with `Error: please run this again with sudo`. A per-user LaunchAgent cannot satisfy this, so this task uses a system-wide **LaunchDaemon** instead, following the same one-time-interactive-sudo pattern as Task 2's system-trust step: the script prepares everything it can without privilege, then prints the exact commands for the human to run themselves, and exits non-zero asking them to re-run afterward.

**Second correction (discovered running as root):** a root LaunchDaemon has no `DOCKER_HOST` set and no access to the invoking user's Docker CLI context, so it falls back to `/var/run/docker.sock` — which is frequently a stale/broken symlink left by Docker Desktop (confirmed on this Mac: it pointed at a non-existent `~/.docker/run/docker.sock`, while the real active runtime was OrbStack at `~/.orbstack/run/docker.sock`). The script must resolve the current user's actual Docker context endpoint and bake it into the plist's `EnvironmentVariables.DOCKER_HOST`, rather than relying on the daemon's default socket path.

**Third correction (discovered verifying the fix):** plain `command -v docker` is not reliable enough for this — some shell environments (e.g. a non-interactive script runner) don't have the user's full interactive PATH, so `docker` may not resolve even though it's installed (confirmed on this Mac: OrbStack's `docker` binary lives at `~/.orbstack/bin/docker` and isn't always on `PATH`). The script checks a short list of well-known locations, not just `PATH`.

**Fourth correction (discovered after finally getting the daemon to stay up):** even with `DOCKER_HOST` correctly set, the daemon still logged `no supported container runtime found`. Root cause, confirmed by reading `cloud-provider-kind`'s own source (`pkg/container/container.go`): it detects the runtime by literally shelling out to `docker info` (`exec.Command("docker", "info")`), not via a Go client library that would honor `DOCKER_HOST` for detection — and launchd's default `PATH` for a LaunchDaemon is just `/usr/bin:/bin:/usr/sbin:/sbin`, which doesn't contain `docker` at all. The plist's `EnvironmentVariables` must also set `PATH` (including the directory the resolved `docker` binary lives in), not just `DOCKER_HOST`.

- [ ] **Step 1: Write `scripts/cloudprovider-bootstrap.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and run standalone**

Run: `chmod +x scripts/cloudprovider-bootstrap.sh && ./scripts/cloudprovider-bootstrap.sh`
Expected: on first run, installs the binary (may take a minute for `go install`), then prints the `sudo cp`/`sudo launchctl bootout ...; sudo launchctl bootstrap ...` instructions and exits non-zero (exit 1) — this is expected, not a failure. Manually run the printed commands yourself in a real terminal (not as part of this scripted verification, since it needs an interactive password), then re-run `./scripts/cloudprovider-bootstrap.sh` again. If the daemon was already installed from a prior attempt but not running, this same run detects that (`plist_installed && ! cpk_running`) and reprints fresh instructions with a corrected `DOCKER_HOST` — this is the path that recovers from a daemon that's installed but crash-looping.

- [ ] **Step 3: Verify it's actually running and idempotent**

Run: `pgrep -x cloud-provider-kind && ./scripts/cloudprovider-bootstrap.sh`
Expected: first command prints a PID; second run prints `cloud-provider-kind already bootstrapped, skipping` and exits 0. Also check `sudo cat /var/log/cloud-provider-kind.err.log` shows no repeating `Error: no supported container runtime found` — if it does, `docker_host()` resolved the wrong endpoint and needs investigating (compare against `docker context inspect "$(docker context show)" --format '{{.Endpoints.docker.Host}}'` run as the regular user).

- [ ] **Step 4: Wire it into `bootstrap.sh`**

Edit `bootstrap.sh`:

```bash
main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst

  "${SCRIPT_DIR}/stepca-bootstrap.sh"
  "${SCRIPT_DIR}/cloudprovider-bootstrap.sh"

  log "kind-lab bootstrap complete"
}
```

- [ ] **Step 5: Commit**

```bash
git add scripts/cloudprovider-bootstrap.sh bootstrap.sh
git commit -m "feat: add idempotent cloud-provider-kind host bootstrap"
```

---

## Task 3b: cloud-provider-kind stale-connection recovery (follow-up)

**Discovered during Task 7:** after `kind delete cluster` + `kind create cluster` (a full teardown/rebuild — exactly what Task 10's final acceptance test does), the already-running `cloud-provider-kind` LaunchDaemon got stuck retrying against the *previous* cluster's API server port and never assigned a `LoadBalancer` IP to the new cluster's Gateway Service. Confirmed via `/var/log/cloud-provider-kind.err.log` showing repeated `connection refused` against the stale port, while `docker ps` showed the current cluster's API server on a different port. Manual recovery: `sudo launchctl kickstart -k system/com.kind.cloud-provider-kind`.

**Files:**
- Investigate/modify: `scripts/cloudprovider-bootstrap.sh` (Task 3's file, already reviewed — reopen deliberately for this fix)
- Possibly modify: `scripts/cluster-up.sh` or `scripts/cluster-down.sh` (Task 4), if the right fix is triggering a restart at the point the cluster is actually recreated, rather than in the bootstrap-time detection script

**This task is investigation-first, not a pre-specified diff.** cloud-provider-kind is designed to watch all kind clusters persistently across many create/delete cycles via Docker events — this "stuck on stale port" behavior may not be a fundamental, always-reproducing bug (it could be timing/backoff-related, or specific to this Mac's OrbStack setup). Before writing a fix:

1. Reproduce: run `./scripts/cluster-down.sh && ./scripts/cluster-up.sh` (full teardown + rebuild) against the live cluster and observe whether `cloud-provider-kind` recovers on its own (check `/var/log/cloud-provider-kind.err.log` and whether the Gateway's Service eventually gets an `EXTERNAL-IP`) — give it a real, generous wait (a few minutes), not just a quick check.
2. If it never self-heals: decide the right fix based on what the logs actually show. Options to consider, in rough order of preference:
   - Extend `cloudprovider-bootstrap.sh`'s detection to verify the daemon can actually reach the *current* cluster's API server (not just that the process is running), and if not, print the `sudo launchctl kickstart -k system/com.kind.cloud-provider-kind` instructions and exit non-zero — same interactive-sudo pattern already used for the trust-store and initial-install steps.
   - Or: if the stale-connection problem is specifically triggered at the moment of cluster recreation, a targeted restart call from `cluster-up.sh` right after creating a new cluster might be more precise (but this still needs sudo, so it can't be silent — same print-instructions-and-die pattern applies).
3. If it DOES self-heal given enough time: no code fix needed — just document the expected recovery time in a comment/log message so it isn't mistaken for a hang, and update this task's notes accordingly.

- [ ] **Step 1: Reproduce and diagnose** (see above)
- [ ] **Step 2: Implement whichever fix the diagnosis points to**
- [ ] **Step 3: Verify** — a real teardown + rebuild cycle must end with the Gateway's Service getting a real `EXTERNAL-IP`, without requiring manual `sudo launchctl kickstart` intervention (a single interactive sudo prompt from a printed instruction, mirroring the existing pattern, is acceptable — a silent hang is not)
- [ ] **Step 4: Commit** with a `fix:` Conventional Commit message describing what was found and fixed

---

## Task 4: kind cluster creation

**Files:**
- Create: `cluster/kind-config.yaml`
- Create: `scripts/cluster-up.sh`
- Create: `scripts/cluster-down.sh`
- Create: `scripts/cluster-status.sh` (partial — just node health for now, extended in later tasks)
- Modify: `bootstrap.sh` (call `cluster-up.sh`)

**Interfaces:**
- Produces: a running kind cluster named `${CLUSTER_NAME}` (context `kind-${CLUSTER_NAME}`), nodes named `${CLUSTER_NAME}-control-plane`, `${CLUSTER_NAME}-worker`, `${CLUSTER_NAME}-worker2`. Nodes will show `NotReady` until Task 5 installs a CNI — that's expected at this point.
- Consumes: `CLUSTER_NAME` from `lib.sh`.

- [ ] **Step 1: Write `cluster/kind-config.yaml`**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind-lab
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

- [ ] **Step 2: Write `scripts/cluster-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

main() {
  require_cmd kind kubectl

  if cluster_exists; then
    log "kind cluster '${CLUSTER_NAME}' already exists, skipping creation"
  else
    log "creating kind cluster '${CLUSTER_NAME}'"
    kind create cluster --config "${REPO_ROOT}/cluster/kind-config.yaml"
  fi

  kubectl cluster-info --context "kind-${CLUSTER_NAME}"
}

main "$@"
```

- [ ] **Step 3: Write `scripts/cluster-down.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  require_cmd kind
  kind delete cluster --name "${CLUSTER_NAME}"
}

main "$@"
```

- [ ] **Step 4: Write `scripts/cluster-status.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  require_cmd kubectl
  echo "--- Nodes ---"
  kubectl get nodes
}

main "$@"
```

- [ ] **Step 5: Make scripts executable and create the cluster**

Run: `chmod +x scripts/cluster-up.sh scripts/cluster-down.sh scripts/cluster-status.sh && ./scripts/cluster-up.sh`
Expected: kind creates 3 containers/nodes, ends with `kubectl cluster-info` output showing the control plane URL.

- [ ] **Step 6: Verify nodes exist (expected NotReady — no CNI yet)**

Run: `./scripts/cluster-status.sh`
Expected: 3 nodes listed, `STATUS` column shows `NotReady` for all of them — this is correct at this stage.

- [ ] **Step 7: Verify idempotency**

Run: `./scripts/cluster-up.sh`
Expected: `kind cluster 'kind-lab' already exists, skipping creation`, then cluster-info output again.

- [ ] **Step 8: Wire into `bootstrap.sh`**

```bash
main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst

  "${SCRIPT_DIR}/stepca-bootstrap.sh"
  "${SCRIPT_DIR}/cloudprovider-bootstrap.sh"
  "${SCRIPT_DIR}/cluster-up.sh"

  log "kind-lab bootstrap complete"
}
```

- [ ] **Step 9: Commit**

```bash
git add cluster/kind-config.yaml scripts/cluster-up.sh scripts/cluster-down.sh scripts/cluster-status.sh bootstrap.sh
git commit -m "feat: add kind cluster creation with Cilium-ready networking config"
```

---

## Task 5: Gateway API CRDs + Cilium (CNI + Gateway API)

**Files:**
- Create: `helm/cilium/values.yaml`
- Create: `scripts/cilium-up.sh`
- Modify: `bootstrap.sh`, `scripts/cluster-status.sh`

**Interfaces:**
- Consumes: a running kind cluster (Task 4).
- Produces: a `Ready` cluster (all 3 nodes), a `GatewayClass` named `cilium` with `ACCEPTED: True`, available for later `Gateway` resources to reference.

**Correction (discovered during implementation):** the values below (Gateway API v1.2.0 standard channel, no `nodePort.enabled`) get the cluster to `Ready` but leave `GatewayClass cilium` stuck at `ACCEPTED: Unknown` forever — node-readiness alone doesn't prove the actual deliverable works. Root-caused via `cilium-operator` logs, two real issues:
1. Cilium's Gateway API controller requires `--enable-node-port` (or full kube-proxy replacement) — logs `"Gateway API support requires either kube-proxy-replacement or enable-node-port enabled"` otherwise. Fix: add `nodePort.enabled: true` to `helm/cilium/values.yaml`, alongside (not instead of) `kubeProxyReplacement: false`.
2. Gateway API `v1.2.0` **standard channel** CRDs don't work with Cilium 1.16.5: Cilium's controller needs the `TLSRoute` CRD (only shipped in the **experimental** channel manifest) just to start reconciling `GatewayClass` status, and separately v1.2.0 changed the `supportedFeatures` status field from `[]string` to `[]object`, which Cilium 1.16.5 (built against the pre-v1.2 schema) can't write against. Fix: pin to Gateway API **`v1.1.0` experimental channel** (`experimental-install.yaml`) instead of `v1.2.0` standard channel.

**Known limitation (discovered during Task 10, not fixed — human decision: document only, revisit if it recurs):** on a genuinely fresh cluster, `install_gateway_api_crds` (this task's `kubectl apply -f .../experimental-install.yaml`) can race `cloud-provider-kind`'s own embedded Gateway API controller-runtime manager. `cloud-provider-kind` connects to the API server almost immediately after cluster creation and, as part of its own (separate, unrelated) Gateway API handling, can cause the API server to record a `v1` storage version for `backendtlspolicies`/`tlsroutes` — two alpha-only CRDs that Gateway API v1.1.0 doesn't define a `v1` version for. Once `status.storedVersions` contains `v1`, the apiserver refuses `cilium-up.sh`'s apply (a built-in CRD safety check), killing the bootstrap under `set -e`. Reproduced on the first clean `cluster-down.sh && bootstrap.sh` rebuild in this project's history; recovered live via:

```bash
kubectl patch crd backendtlspolicies.gateway.networking.k8s.io --subresource=status --type=merge -p '{"status":{"storedVersions":["v1alpha3"]}}'
kubectl patch crd tlsroutes.gateway.networking.k8s.io --subresource=status --type=merge -p '{"status":{"storedVersions":["v1alpha2"]}}'
```

Not yet scripted into `install_gateway_api_crds`. If this recurs, a reasonable fix would be having `install_gateway_api_crds` detect this exact conflict and self-heal via the same patch before retrying, or checking whether `cloud-provider-kind` can be configured to skip its own Gateway API CRD management (this project only needs Cilium's Gateway API implementation, not `cloud-provider-kind`'s).

The script below also adds a `gatewayclass_accepted` check — verifying the real acceptance criterion, not just node readiness, is what surfaces issue #2 in the first place.

- [ ] **Step 1: Write `helm/cilium/values.yaml`**

```yaml
kubeProxyReplacement: false
nodePort:
  enabled: true
gatewayAPI:
  enabled: true
ipam:
  mode: kubernetes
operator:
  replicas: 1
```

- [ ] **Step 2: Write `scripts/cilium-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

GATEWAY_API_VERSION="v1.1.0"
CILIUM_VERSION="1.16.5"

install_gateway_api_crds() {
  log "applying Gateway API CRDs (${GATEWAY_API_VERSION}, experimental channel)"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
}

install_cilium() {
  log "installing Cilium ${CILIUM_VERSION} (CNI + Gateway API)"
  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values "${SCRIPT_DIR}/../helm/cilium/values.yaml" \
    --kube-context "kind-${CLUSTER_NAME}" \
    --wait --timeout 5m
}

nodes_ready() {
  local not_ready
  not_ready=$(kubectl get nodes --no-headers | grep -vc " Ready ")
  [ "${not_ready}" -eq 0 ]
}

gatewayclass_accepted() {
  [ "$(kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = "True" ]
}

main() {
  require_cmd kubectl helm
  install_gateway_api_crds
  install_cilium
  wait_for "all nodes Ready" 180 nodes_ready
  wait_for "GatewayClass 'cilium' accepted" 120 gatewayclass_accepted
  log "Cilium installed and cluster is Ready"
}

main "$@"
```

- [ ] **Step 3: Make executable and run**

Run: `chmod +x scripts/cilium-up.sh && ./scripts/cilium-up.sh`
Expected: Gateway API CRDs applied, Cilium Helm release installs (this can take 2-3 minutes), ends with `all nodes Ready: ready` and `Cilium installed and cluster is Ready`.

- [ ] **Step 4: Verify nodes are Ready and GatewayClass exists**

Run: `kubectl get nodes && kubectl get gatewayclass`
Expected: all 3 nodes show `Ready`; a `GatewayClass` named `cilium` is listed with `ACCEPTED: True`.

- [ ] **Step 5: Verify idempotency**

Run: `./scripts/cilium-up.sh`
Expected: Helm reports the release is already up to date (or reapplies with no changes), still ends with `Cilium installed and cluster is Ready`.

- [ ] **Step 6: Extend `scripts/cluster-status.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  require_cmd kubectl
  echo "--- Nodes ---"
  kubectl get nodes
  echo "--- Cilium ---"
  kubectl -n kube-system get pods -l k8s-app=cilium
  echo "--- GatewayClass ---"
  kubectl get gatewayclass
}

main "$@"
```

- [ ] **Step 7: Wire into `bootstrap.sh`**

```bash
  "${SCRIPT_DIR}/cluster-up.sh"
  "${SCRIPT_DIR}/cilium-up.sh"
```

- [ ] **Step 8: Commit**

```bash
git add helm/cilium/values.yaml scripts/cilium-up.sh scripts/cluster-status.sh bootstrap.sh
git commit -m "feat: install Cilium as CNI and Gateway API implementation"
```

---

## Task 6: cert-manager

**Files:**
- Create: `helm/cert-manager/values.yaml`
- Create: `scripts/cert-manager-up.sh`
- Modify: `bootstrap.sh`, `scripts/cluster-status.sh`

**Interfaces:**
- Consumes: a Ready cluster (Task 5).
- Produces: `cert-manager` namespace with the controller/webhook/cainjector running, Gateway API feature gate enabled, so `ClusterIssuer`/`Certificate` resources and HTTP-01-via-Gateway solving work.

**Correction (discovered during Task 10):** the values below get all three deployments Running, but Gateway API HTTP-01 solving silently fails at Challenge time with `"gateway api is not enabled"` — this wasn't caught by Task 6's own acceptance criteria (deployments Running) since nothing in Task 6 actually exercises Gateway API solving. Root-caused by reading cert-manager v1.16.2 source (`pkg/controller/context.go`, `pkg/issuer/acme/http/http.go`): as of cert-manager v1.15+, enabling Gateway API HTTP-01 support requires **both** the `ExperimentalGatewayAPISupport` feature gate as a `ControllerConfiguration` file (not the `--feature-gates` CLI flag) **and** a separate `--enable-gateway-api` CLI flag. Neither the CLI-flag-only feature gate alone, nor the flag alone, is sufficient — both are required together.

- [ ] **Step 1: Write `helm/cert-manager/values.yaml`**

```yaml
installCRDs: true
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  featureGates:
    ExperimentalGatewayAPISupport: true
extraArgs:
  - --enable-gateway-api
```

- [ ] **Step 2: Write `scripts/cert-manager-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CERT_MANAGER_VERSION="v1.16.2"

install_cert_manager() {
  log "installing cert-manager ${CERT_MANAGER_VERSION}"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace \
    --values "${SCRIPT_DIR}/../helm/cert-manager/values.yaml" \
    --kube-context "kind-${CLUSTER_NAME}" \
    --wait --timeout 5m
}

main() {
  require_cmd kubectl helm
  install_cert_manager
  kubectl -n cert-manager rollout status deployment/cert-manager --timeout=120s
  kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=120s
  kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=120s
  log "cert-manager installed and ready"
}

main "$@"
```

- [ ] **Step 3: Make executable and run**

Run: `chmod +x scripts/cert-manager-up.sh && ./scripts/cert-manager-up.sh`
Expected: Helm install completes, all three rollout status checks pass, ends with `cert-manager installed and ready`.

- [ ] **Step 4: Verify**

Run: `kubectl -n cert-manager get pods`
Expected: 3 pods (`cert-manager-*`, `cert-manager-webhook-*`, `cert-manager-cainjector-*`), all `Running` and `1/1 Ready`.

- [ ] **Step 5: Extend `scripts/cluster-status.sh`** — add after the GatewayClass section:

```bash
  echo "--- cert-manager ---"
  kubectl -n cert-manager get pods
```

- [ ] **Step 6: Wire into `bootstrap.sh`**

```bash
  "${SCRIPT_DIR}/cilium-up.sh"
  "${SCRIPT_DIR}/cert-manager-up.sh"
```

- [ ] **Step 7: Commit**

```bash
git add helm/cert-manager/values.yaml scripts/cert-manager-up.sh scripts/cluster-status.sh bootstrap.sh
git commit -m "feat: install cert-manager with Gateway API HTTP-01 support"
```

---

## Task 7: Shared Gateway

**Files:**
- Create: `helm/gateway/gateway.yaml`
- Modify: `bootstrap.sh` (apply it + wait for LB IP), `scripts/cluster-status.sh`

**Interfaces:**
- Consumes: `GatewayClass: cilium` (Task 5).
- Produces: `Gateway` named `lab-gateway` in namespace `lab-gateway`, with one listener named `http` (port 80, any hostname, `allowedRoutes.namespaces.from: All`). Its Cilium-created `Service` (type `LoadBalancer`) is what later tasks read the assigned IP from. Later sub-projects (and Task 9's smoke test) add their own named listener to this same `Gateway` object for their own hostname + TLS cert — Gateway API's listener model requires each hostname+cert pair to be its own listener on the shared object, so extending it means re-applying an updated copy of this file with an additional listener appended, not creating a second `Gateway`.

**Correction (discovered during Task 10):** the "one shared wildcard `http` listener for all future hostnames" pattern described above does not actually work with Cilium 1.16.5's Gateway API implementation once a second, per-hostname HTTPS listener exists on the same `Gateway`. Cilium silently drops all routing through the wildcard `http` listener for any hostname that's claimed exactly by another listener on that `Gateway` (upstream bug [cilium/cilium#44123](https://github.com/cilium/cilium/issues/44123), unresolved as of this writing) — confirmed by cloning `cilium/cilium` v1.16.5 and tracing `operator/pkg/model/helpers.go`'s `ComputeHosts`/`checkHostNameIsolation`. In practice this broke cert-manager's HTTP-01 solving for Task 10's smoke test: the auto-generated solver `HTTPRoute` (hostname `smoke.lab.test`, targeting the shared `http` listener) got silently excluded once the `https-smoke` listener (which claims `smoke.lab.test`) existed, and the generated `CiliumEnvoyConfig` simply had no route config for the `http` listener at all. The workaround applied in Task 10 (`helm/smoke-test/gateway-patch.yaml`) is to give the `http` listener the *same* explicit hostname as its paired HTTPS listener — meaning **every future per-hostname HTTPS listener will need its own matching per-hostname HTTP listener too**, not one shared wildcard `http` listener, until Cilium fixes the upstream issue or this project moves its ACME solving from HTTP-01 to DNS-01 (which doesn't route through Gateway API's HTTP listener at all). See `helm/smoke-test/gateway-patch.yaml` for the workaround in place and CLAUDE.md's "Open decisions" for the broader tracking note.

- [ ] **Step 1: Write `helm/gateway/gateway.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lab-gateway
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: lab-gateway
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 2: Apply it manually and verify a LoadBalancer IP gets assigned**

Run: `kubectl apply -f helm/gateway/gateway.yaml && sleep 10 && kubectl -n lab-gateway get gateway,svc`
Expected: the `Gateway/lab-gateway` row shows `PROGRAMMED: True`; a `Service` of `TYPE: LoadBalancer` exists with a non-empty `EXTERNAL-IP` (assigned by `cloud-provider-kind` from Task 3).

- [ ] **Step 3: Wire into `bootstrap.sh`** — add a `gateway_has_ip` check function and call it after cert-manager:

```bash
gateway_has_ip() {
  local ip
  ip=$(kubectl -n lab-gateway get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{end}' 2>/dev/null)
  [ -n "${ip}" ]
}

main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst

  "${SCRIPT_DIR}/stepca-bootstrap.sh"
  "${SCRIPT_DIR}/cloudprovider-bootstrap.sh"
  "${SCRIPT_DIR}/cluster-up.sh"
  "${SCRIPT_DIR}/cilium-up.sh"
  "${SCRIPT_DIR}/cert-manager-up.sh"

  log "applying shared lab-gateway"
  kubectl apply -f "${SCRIPT_DIR}/../helm/gateway/gateway.yaml"
  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip

  log "kind-lab bootstrap complete"
}
```

- [ ] **Step 4: Run full bootstrap and verify**

Run: `./bootstrap.sh`
Expected: completes through `lab-gateway has a LoadBalancer IP: ready` and ends with `kind-lab bootstrap complete`.

- [ ] **Step 5: Extend `scripts/cluster-status.sh`** — add after cert-manager section:

```bash
  echo "--- lab-gateway ---"
  kubectl -n lab-gateway get gateway,svc
```

- [ ] **Step 6: Commit**

```bash
git add helm/gateway/gateway.yaml bootstrap.sh scripts/cluster-status.sh
git commit -m "feat: add shared lab-gateway Gateway resource"
```

---

## Task 8: In-cluster DNS (dnsmasq) + macOS resolver

**Files:**
- Create: `helm/dns/dnsmasq.yaml.tmpl`
- Create: `scripts/dns-bootstrap.sh`
- Modify: `bootstrap.sh`, `scripts/cluster-status.sh`

**Interfaces:**
- Consumes: `lab-gateway`'s assigned `LoadBalancer` IP (Task 7), `CLUSTER_NAME` from `lib.sh` (to derive the control-plane node's name: `${CLUSTER_NAME}-control-plane`).
- Produces: `*.lab.test` resolves (via macOS's `/etc/resolver/lab.test`) to `lab-gateway`'s IP, from any process on the Mac (including `curl`, `step-ca`'s ACME validator, and a browser).

- [ ] **Step 1: Write `helm/dns/dnsmasq.yaml.tmpl`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dns-utils
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dnsmasq-config
  namespace: dns-utils
data:
  dnsmasq.conf: |
    no-resolv
    address=/lab.test/${GATEWAY_IP}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dnsmasq
  namespace: dns-utils
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dnsmasq
  template:
    metadata:
      labels:
        app: dnsmasq
    spec:
      containers:
        - name: dnsmasq
          image: dockurr/dnsmasq:latest
          args: ["-C", "/etc/dnsmasq.conf", "-k"]
          ports:
            - containerPort: 53
              protocol: UDP
            - containerPort: 53
              protocol: TCP
          volumeMounts:
            - name: config
              mountPath: /etc/dnsmasq.conf
              subPath: dnsmasq.conf
      volumes:
        - name: config
          configMap:
            name: dnsmasq-config
---
apiVersion: v1
kind: Service
metadata:
  name: dnsmasq
  namespace: dns-utils
spec:
  type: NodePort
  selector:
    app: dnsmasq
  ports:
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
      nodePort: 30053
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
      nodePort: 30053
```

- [ ] **Step 2: Write `scripts/dns-bootstrap.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

RESOLVER_FILE="/etc/resolver/${LAB_DOMAIN}"

gateway_ip() {
  kubectl -n lab-gateway get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{end}'
}

node_ip() {
  kubectl get node "${CLUSTER_NAME}-control-plane" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

resolver_up_to_date() {
  local node
  node=$(node_ip)
  [ -f "${RESOLVER_FILE}" ] && grep -q "nameserver ${node}" "${RESOLVER_FILE}" && grep -q "port 30053" "${RESOLVER_FILE}"
}

main() {
  require_cmd kubectl envsubst sudo

  local gw_ip
  gw_ip=$(gateway_ip)
  [ -n "${gw_ip}" ] || die "lab-gateway has no LoadBalancer IP yet — run cluster-up/cilium-up/cert-manager-up first"

  log "applying dnsmasq (resolving *.${LAB_DOMAIN} -> ${gw_ip})"
  GATEWAY_IP="${gw_ip}" envsubst '${GATEWAY_IP}' < "${SCRIPT_DIR}/../helm/dns/dnsmasq.yaml.tmpl" | kubectl apply -f -
  kubectl -n dns-utils rollout status deployment/dnsmasq --timeout=60s

  if resolver_up_to_date; then
    log "${RESOLVER_FILE} already up to date, skipping"
    return 0
  fi

  local node
  node=$(node_ip)
  log "writing ${RESOLVER_FILE} (nameserver ${node}, port 30053) — requires sudo"
  sudo mkdir -p /etc/resolver
  printf 'nameserver %s\nport 30053\n' "${node}" | sudo tee "${RESOLVER_FILE}" >/dev/null
}

main "$@"
```

- [ ] **Step 3: Make executable and run**

Run: `chmod +x scripts/dns-bootstrap.sh && ./scripts/dns-bootstrap.sh`
Expected: dnsmasq deploys and rolls out, then (with a sudo prompt) writes `/etc/resolver/lab.test`.

- [ ] **Step 4: Verify DNS resolution actually works**

**Correction (discovered during implementation):** plain `dig` bypasses macOS's per-domain resolver mechanism entirely — it reads `/etc/resolv.conf` directly rather than going through the SystemConfiguration/`getaddrinfo()` path that actually honors `/etc/resolver/*`, so `dig smoke.lab.test` (no explicit `@server`) returns `NXDOMAIN` even when the resolver is working correctly. Use a `getaddrinfo()`-based check instead:

Run: `python3 -c "import socket; print(socket.gethostbyname('smoke.lab.test'))"` (or `scutil --dns | grep -A5 lab.test` to confirm the resolver is registered)
Expected: prints the same IP as `kubectl -n lab-gateway get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{end}'`.

- [ ] **Step 5: Verify idempotency**

Run: `./scripts/dns-bootstrap.sh`
Expected: dnsmasq re-applies cleanly (no changes), prints `/etc/resolver/lab.test already up to date, skipping` (no second sudo prompt).

- [ ] **Step 6: Extend `scripts/cluster-status.sh`** — add after lab-gateway section:

```bash
  echo "--- dnsmasq ---"
  kubectl -n dns-utils get pods,svc
```

- [ ] **Step 7: Wire into `bootstrap.sh`** — after the `wait_for "lab-gateway has a LoadBalancer IP"` line:

```bash
  "${SCRIPT_DIR}/dns-bootstrap.sh"
```

- [ ] **Step 8: Commit**

```bash
git add helm/dns/dnsmasq.yaml.tmpl scripts/dns-bootstrap.sh scripts/cluster-status.sh bootstrap.sh
git commit -m "feat: add in-cluster dnsmasq and macOS resolver for *.lab.test"
```

---

## Task 9: step-ca ACME ClusterIssuer

**Files:**
- Create: `helm/cluster-issuer/issuer.yaml.tmpl`
- Create: `scripts/issuer-up.sh`
- Modify: `bootstrap.sh`, `scripts/cluster-status.sh`

**Interfaces:**
- Consumes: `lab-gateway`'s `http` listener (Task 7, for the HTTP-01 solver's `parentRefs`), step-ca's ACME directory (Task 2, host `<hostname>.local:9443`), `~/.step/certs/root_ca.crt` (for `caBundle`).
- Produces: `ClusterIssuer` named `step-ca-acme` — later `Certificate` resources (Task 10) reference it via `issuerRef: {name: step-ca-acme, kind: ClusterIssuer}`.

- [ ] **Step 1: Write `helm/cluster-issuer/issuer.yaml.tmpl`**

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-ca-acme
spec:
  acme:
    server: https://${STEPCA_HOST}:${STEPCA_PORT}/acme/acme/directory
    caBundle: ${STEPCA_ROOT_CA_B64}
    privateKeySecretRef:
      name: step-ca-acme-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: lab-gateway
                namespace: lab-gateway
                kind: Gateway
                sectionName: http
```

- [ ] **Step 2: Write `scripts/issuer-up.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

issuer_ready() {
  [ "$(kubectl get clusterissuer step-ca-acme -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

main() {
  require_cmd kubectl envsubst scutil openssl base64

  local host
  host="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
  export STEPCA_HOST="${host}"
  export STEPCA_PORT
  export STEPCA_ROOT_CA_B64
  STEPCA_ROOT_CA_B64=$(base64 < "${HOME}/.step/certs/root_ca.crt" | tr -d '\n')

  log "applying step-ca ACME ClusterIssuer (server https://${STEPCA_HOST}:${STEPCA_PORT}/acme/acme/directory)"
  envsubst '${STEPCA_HOST} ${STEPCA_PORT} ${STEPCA_ROOT_CA_B64}' < "${SCRIPT_DIR}/../helm/cluster-issuer/issuer.yaml.tmpl" | kubectl apply -f -
  wait_for "ClusterIssuer step-ca-acme Ready" 60 issuer_ready
}

main "$@"
```

- [ ] **Step 3: Make executable and run**

Run: `chmod +x scripts/issuer-up.sh && ./scripts/issuer-up.sh`
Expected: applies the `ClusterIssuer`, ends with `ClusterIssuer step-ca-acme Ready: ready`.

- [ ] **Step 4: Verify**

Run: `kubectl describe clusterissuer step-ca-acme`
Expected: `Status.Conditions` shows `Type: Ready, Status: True`, and `Status.ACME.LastRegisteredEmail`/URI fields are populated (proves it successfully registered an ACME account against step-ca).

- [ ] **Step 5: Verify idempotency**

Run: `./scripts/issuer-up.sh`
Expected: re-applies with no changes, still ends `Ready: ready`.

- [ ] **Step 6: Extend `scripts/cluster-status.sh`** — add after dnsmasq section:

```bash
  echo "--- ClusterIssuer ---"
  kubectl get clusterissuer step-ca-acme
```

- [ ] **Step 7: Wire into `bootstrap.sh`** — after the dns-bootstrap call:

```bash
  "${SCRIPT_DIR}/issuer-up.sh"
```

- [ ] **Step 8: Commit**

```bash
git add helm/cluster-issuer/issuer.yaml.tmpl scripts/issuer-up.sh scripts/cluster-status.sh bootstrap.sh
git commit -m "feat: add step-ca ACME ClusterIssuer"
```

---

## Task 10: Smoke test app + end-to-end verification

**Files:**
- Create: `helm/smoke-test/gateway-patch.yaml`
- Create: `helm/smoke-test/certificate.yaml`
- Create: `helm/smoke-test/app.yaml`
- Create: `scripts/smoke-test.sh`
- Modify: `bootstrap.sh`, `Taskfile.yaml` (already has `smoke:test`, no change needed there)

**Interfaces:**
- Consumes: `lab-gateway` (Task 7, extended here with an `https-smoke` listener), `step-ca-acme` `ClusterIssuer` (Task 9).
- Produces: `https://smoke.lab.test` serving nginx over a step-ca-issued, Mac-trusted TLS certificate — the sub-project's definition of done.

- [ ] **Step 1: Write `helm/smoke-test/gateway-patch.yaml`** (full replacement of the Gateway spec, adding the `https-smoke` listener alongside the existing `http` one — this is the pattern later sub-projects follow to add their own hostname+cert to the shared Gateway)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: lab-gateway
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https-smoke
      protocol: HTTPS
      port: 443
      hostname: smoke.lab.test
      tls:
        mode: Terminate
        certificateRefs:
          - name: smoke-tls
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 2: Write `helm/smoke-test/certificate.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: smoke-tls
  namespace: lab-gateway
spec:
  secretName: smoke-tls
  dnsNames:
    - smoke.lab.test
  issuerRef:
    name: step-ca-acme
    kind: ClusterIssuer
```

- [ ] **Step 3: Write `helm/smoke-test/app.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: smoke-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke-nginx
  namespace: smoke-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: smoke-nginx
  template:
    metadata:
      labels:
        app: smoke-nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: smoke-nginx
  namespace: smoke-test
spec:
  selector:
    app: smoke-nginx
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: smoke-nginx
  namespace: smoke-test
spec:
  parentRefs:
    - name: lab-gateway
      namespace: lab-gateway
      sectionName: https-smoke
  hostnames:
    - smoke.lab.test
  rules:
    - backendRefs:
        - name: smoke-nginx
          port: 80
```

- [ ] **Step 4: Write `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
HELM_DIR="${SCRIPT_DIR}/../helm/smoke-test"

apply_manifests() {
  kubectl apply -f "${HELM_DIR}/gateway-patch.yaml"
  kubectl apply -f "${HELM_DIR}/certificate.yaml"
  kubectl apply -f "${HELM_DIR}/app.yaml"
}

cert_ready() {
  [ "$(kubectl -n lab-gateway get certificate smoke-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

verify_https() {
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' --cacert "${HOME}/.step/certs/root_ca.crt" --max-time 5 "https://smoke.${LAB_DOMAIN}" 2>/dev/null || echo "000")
  [ "${status}" = "200" ]
}

main() {
  require_cmd kubectl curl
  apply_manifests
  kubectl -n smoke-test rollout status deployment/smoke-nginx --timeout=60s
  wait_for "Certificate smoke-tls Ready" 90 cert_ready
  wait_for "https://smoke.${LAB_DOMAIN} returns 200" 60 verify_https
  log "smoke test passed: https://smoke.${LAB_DOMAIN} is served with a trusted cert"
}

main "$@"
```

- [ ] **Step 5: Make executable and run standalone**

Run: `chmod +x scripts/smoke-test.sh && ./scripts/smoke-test.sh`
Expected: nginx deploys, the Gateway gets its second listener, cert-manager issues `smoke-tls` via ACME HTTP-01 (may take 10-30s), and it ends with `smoke test passed: https://smoke.lab.test is served with a trusted cert`.

- [ ] **Step 6: Manually verify with a browser or curl, no `-k`/`--cacert` override**

Run: `curl -sI https://smoke.lab.test`
Expected: `HTTP/2 200` with no certificate warning/error (curl trusts it via the macOS System keychain automatically, no `--cacert` flag needed here since the root is now system-trusted).

- [ ] **Step 7: Verify idempotency**

Run: `./scripts/smoke-test.sh`
Expected: all manifests re-apply with no changes, still passes both `wait_for` checks quickly (cert already `Ready`, curl already returns 200).

- [ ] **Step 8: Wire into `bootstrap.sh`** — final version of `main()`:

```bash
main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst

  "${SCRIPT_DIR}/stepca-bootstrap.sh"
  "${SCRIPT_DIR}/cloudprovider-bootstrap.sh"
  "${SCRIPT_DIR}/cluster-up.sh"
  "${SCRIPT_DIR}/cilium-up.sh"
  "${SCRIPT_DIR}/cert-manager-up.sh"

  log "applying shared lab-gateway"
  kubectl apply -f "${SCRIPT_DIR}/../helm/gateway/gateway.yaml"
  wait_for "lab-gateway has a LoadBalancer IP" 60 gateway_has_ip

  "${SCRIPT_DIR}/dns-bootstrap.sh"
  "${SCRIPT_DIR}/issuer-up.sh"
  "${SCRIPT_DIR}/smoke-test.sh"

  log "kind-lab bootstrap complete"
}
```

- [ ] **Step 9: Run the entire bootstrap end to end from a clean cluster** (final full-system check)

Run: `./scripts/cluster-down.sh && ./bootstrap.sh`
Expected: full teardown and rebuild completes with no manual intervention (step-ca/cloud-provider-kind steps should both no-op since they're host-level and already set up), ending in `smoke test passed` and `kind-lab bootstrap complete`. This is the sub-project's true end-to-end acceptance test.

- [ ] **Step 10: Commit**

```bash
git add helm/smoke-test/ scripts/smoke-test.sh bootstrap.sh
git commit -m "feat: add smoke-test app and complete end-to-end bootstrap verification"
```

---

## Post-plan check

After Task 10, `task cluster:up` from a completely torn-down state should be a single command that ends with a working `https://smoke.lab.test`. `task cluster:down`, `task cluster:status`, and `task smoke:test` all work standalone. This closes out sub-project 1 — ArgoCD/GitOps (sub-project 2) is the next brainstorming topic.
