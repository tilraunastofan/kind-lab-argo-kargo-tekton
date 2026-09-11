# Cluster Bootstrap + CNI/Gateway API + TLS — Design

Sub-project 1 of the kind-lab build-out (see README.md and CLAUDE.md for full lab scope). This covers everything needed before GitOps (ArgoCD) takes over: a working `kind` cluster with Cilium as CNI + Gateway API implementation, and automatic TLS issuance for cluster workloads.

## Goals

- A `kind` cluster that can be torn down and rebuilt from scratch with one command.
- Gateway API (not Ingress) as the traffic-routing surface, backed by Cilium.
- Real, routable access to in-cluster services by hostname (`*.lab.test`) from the Mac, with no manual `/etc/hosts` editing and no host port juggling.
- Automatic, passwordless TLS certificate issuance for in-cluster workloads, trusted by the host Mac, via a local `step-ca` ACME server.
- A smoke test proving the whole chain (CNI → Gateway API → DNS → cert-manager → ACME → TLS) works end to end, without depending on the "real" demo app.

## Networking model: routable node IPs, not host-port mapping

The Mac already runs Caddy bound to host ports 80/443 for unrelated local services, so kind's containers cannot also bind those ports on the host. The lab's Docker runtime is **OrbStack**, which — unlike plain Docker Desktop — routes container network IPs directly from the Mac (no `docker-mac-net-connect` or similar needed). That means kind's node IPs, and any `LoadBalancer` IP assigned to a Service, are already reachable from the Mac without any port mapping. This makes host-port mapping (and any Caddy passthrough workaround) unnecessary: `kind-config.yaml` carries no `extraPortMappings` at all. All lab traffic — including the ACME HTTP-01 challenge — goes directly to the Gateway's own LoadBalancer IP on its own standard ports 80/443, entirely separate from the Mac's own port 80/443 that Caddy owns.

Two consequences:

- **`cloud-provider-kind`** must run so that `Service.type=LoadBalancer` (which Cilium's Gateway API implementation creates one of, per `Gateway`) actually gets an IP assigned — kind has no cloud provider by default. It's a host-side helper process, same category as `step-ca`: install if missing, run persistently via a launchd agent, idempotent bootstrap.
- **DNS**: `*.lab.test` needs to resolve to whatever IP `cloud-provider-kind` assigned the shared Gateway's Service (this IP is not knowable in advance — it's allocated at cluster-creation time from the Docker network). An in-cluster `dnsmasq` Deployment answers that wildcard, exposed via a `NodePort` Service; macOS's per-domain resolver (`/etc/resolver/lab.test`) is pointed at a node IP + that NodePort. Both the dnsmasq config and the resolver file are regenerated (idempotently) whenever the assigned IP or node IP changes.

## Out of scope (deferred to later sub-projects)

- ArgoCD / GitOps (sub-project 2)
- Datadog Operator (sub-project 3, deployed via ArgoCD)
- The Go demo app + Clickhouse (sub-project 4, deployed via ArgoCD)
- Kargo / promotion pipeline / Forgejo (sub-project 5)

## Host-side step-ca bootstrap (portable, idempotent)

This lab is intended to run on more than one workstation, so `step-ca` setup must be scripted, not a one-off manual prerequisite. `bootstrap.sh` runs `scripts/stepca-bootstrap.sh` as its first step, and that script **only acts on what's actually missing** — on a workstation where step-ca is already fully configured (this Mac, after the work done in this session) it detects that and exits as a no-op; on a fresh workstation it performs full first-time setup.

Detection logic (all must hold for step-ca to be considered "already bootstrapped"):

- `~/.step/config/ca.json` and `~/.step/config/defaults.json` exist.
- The configured ACME directory URL (parsed from `ca.json`'s `address` + `dnsNames`) responds to a health check.
- The launchd agent `com.smallstep.step-ca` is loaded (`launchctl list`).
- The root CA cert's fingerprint is present in the macOS System keychain as a trusted root (`security find-certificate`/`security verify-cert`).

If any of these is false, the script performs the missing piece(s):

1. **PKI init** (if `~/.step` isn't initialized): `step ca init --deployment-type standalone --acme --password-file <empty-temp-file> --provisioner-password-file <empty-temp-file>`, using the workstation's hostname (`scutil --get LocalHostName` / `hostname`) for `dnsNames`, address `:9443`. Immediately strip encryption from both `root_ca_key` and `intermediate_ca_key` using the known temp password (non-interactive `openssl ec -passin file:...`), then shred the temp password file. Result: passwordless keys, matching what this session already produced on this Mac.
2. **launchd agent** (if not loaded): write `~/Library/LaunchAgents/com.smallstep.step-ca.plist` (`RunAtLoad`+`KeepAlive`, pointing at `step-ca ~/.step/config/ca.json`), `launchctl load` it, poll `/health` until it responds.
3. **System trust store** (if the root isn't yet trusted): this is the one step that cannot be automated — it requires an interactive `sudo` password and touches system-wide trust. The script detects this case and prints the exact command for the user to run themselves:
   `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.step/certs/root_ca.crt`
   then exits with a non-zero status and a clear message to re-run `bootstrap.sh` after doing so.

`bootstrap.sh` then continues with cluster creation only once `stepca-bootstrap.sh` reports full success.

## Host-side cloud-provider-kind bootstrap (portable, idempotent)

Same shape as the step-ca bootstrap: `scripts/cloudprovider-bootstrap.sh` runs early in `bootstrap.sh` and is a no-op if already satisfied.

**Correction (discovered during implementation):** `cloud-provider-kind` requires root on macOS to perform its networking setup — it exits immediately with `Error: please run this again with sudo` when run unprivileged. A per-user LaunchAgent cannot satisfy this. Like step-ca's system-trust step, this needs a one-time interactive `sudo` step: it runs as a system-wide **LaunchDaemon** (`/Library/LaunchDaemons/`, root-owned), not a per-user LaunchAgent.

**Second correction (discovered running as root):** a root LaunchDaemon doesn't inherit the invoking user's Docker CLI context, so it falls back to `/var/run/docker.sock` — often a stale symlink (confirmed broken on this Mac, left over from Docker Desktop, while the actual active runtime is OrbStack). The bootstrap script resolves the real endpoint via `docker context inspect` as the regular user and bakes it into the LaunchDaemon's `EnvironmentVariables.DOCKER_HOST`, making it portable across whatever runtime (OrbStack, Docker Desktop, Colima) a given workstation actually uses.

**Third correction (discovered verifying the fix):** locating the `docker` CLI via bare `PATH` lookup isn't reliable in every shell context — OrbStack's `docker` binary (`~/.orbstack/bin/docker`) isn't always on `PATH` outside an interactive terminal. The script checks a short list of known install locations, not just `command -v docker`.

**Fourth correction (discovered after the daemon finally stayed up but still failed):** `cloud-provider-kind` detects its container runtime by shelling out to `docker info` (confirmed by reading its source), not via an env-aware Go client — and a LaunchDaemon's default `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) doesn't contain `docker` at all. The plist's `EnvironmentVariables` must set `PATH` (including the resolved `docker` binary's directory) alongside `DOCKER_HOST`.

Detection logic:

- `cloud-provider-kind` binary is on `PATH` (installed via `go install sigs.k8s.io/cloud-provider-kind@latest` if missing — requires `go` as a prerequisite tool).
- `/Library/LaunchDaemons/com.kind.cloud-provider-kind.plist` exists.
- The process is actually running (`pgrep -x cloud-provider-kind` — checking process presence doesn't require sudo, unlike installing/loading a system daemon).

If the binary is missing, install it (no sudo needed for `go install`). If the daemon isn't installed/running: write the LaunchDaemon plist to a temp file, then print the exact two commands for the user to run themselves (`sudo cp <tmp> /Library/LaunchDaemons/com.kind.cloud-provider-kind.plist` and `sudo launchctl bootstrap system /Library/LaunchDaemons/com.kind.cloud-provider-kind.plist`), then exit non-zero asking them to re-run `bootstrap.sh` afterward — the same pattern as step-ca's system-trust step.

## Architecture

`bootstrap.sh` (invoked via `task cluster:up`) performs, in order:

1. **Prerequisite check** — `kind`, `helm`, `kubectl`, `docker`, `step`, `go`, `curl` on `PATH`. Fail fast with a clear message naming the missing tool.
2. **step-ca bootstrap** — run `scripts/stepca-bootstrap.sh`; no-op if already fully configured on this workstation, otherwise performs first-time setup. If it requires a manual trust-store step, `bootstrap.sh` stops here with instructions.
3. **cloud-provider-kind bootstrap** — run `scripts/cloudprovider-bootstrap.sh`; no-op if already running, otherwise installs and starts it.
4. **Cluster creation** — `kind create cluster` from `cluster/kind-config.yaml`: 1 control-plane + 2 workers, `disableDefaultCNI: true`, explicit `podSubnet: 10.244.0.0/16`. No `extraPortMappings` — see "Networking model" above.
5. **Gateway API CRDs** — apply the upstream Gateway API "standard" channel CRDs (`kubectl apply -f .../standard-install.yaml`). Required before Cilium, since Cilium's Gateway API controller expects the CRDs to pre-exist.
6. **Cilium (CNI + Gateway API)** — install via Helm with `gatewayAPI.enabled=true`; wait for the Cilium DaemonSet/Operator to report ready before continuing (nodes stay `NotReady` until CNI is up).
7. **cert-manager** — install via Helm (`installCRDs=true`), with the Gateway API feature gate enabled so it can solve ACME HTTP-01 challenges via `HTTPRoute` resources instead of `Ingress`.
8. **Shared Gateway** — apply the `lab-gateway` `Gateway` resource (HTTP listener on 80, HTTPS listener on 443, `gatewayClassName: cilium`). This is shared by every future workload in the lab, not just the smoke test. Wait for its Service to be assigned a `LoadBalancer` IP.
9. **DNS** — run `scripts/dns-bootstrap.sh`: template the in-cluster `dnsmasq` Deployment/ConfigMap with `lab-gateway`'s assigned IP, apply it, wait for it to be ready, fetch a node's IP and the dnsmasq NodePort, and (idempotently) write `/etc/resolver/lab.test` pointing at them. Re-run whenever the Gateway IP or node IP has changed since the last run.
10. **ClusterIssuer (ACME)** — apply a `ClusterIssuer` of kind ACME pointed at the step-ca ACME directory URL (host + port detected from the local step-ca config, e.g. `https://<hostname>:9443/acme/acme/directory`), `caBundle` set to the local root CA cert (so cert-manager trusts step-ca's own TLS, distinct from the certs it issues), HTTP-01 solver configured to route through `lab-gateway`.
11. **Smoke test** — apply a throwaway manifest set (`helm/smoke-test/`): an nginx `Deployment`+`Service`, an `HTTPRoute` on `lab-gateway` for `smoke.lab.test`, and a `Certificate` referencing the ACME `ClusterIssuer`.
12. **Verification** — poll until the `Certificate` reaches `Ready`, then `curl --cacert <root_ca.crt> https://smoke.lab.test` and assert HTTP 200 (standard port 443, no port suffix needed — this is the payoff of the routable-IP approach). This is the sub-project's definition of success.

## File layout

```text
kind-lab/
├── Taskfile.yaml
├── bootstrap.sh                  # thin entrypoint, delegates to scripts/
├── scripts/
│   ├── lib.sh                    # shared helpers (log, prereq checks, wait_for)
│   ├── stepca-bootstrap.sh       # idempotent host-side step-ca setup
│   ├── cloudprovider-bootstrap.sh # idempotent host-side cloud-provider-kind setup
│   ├── dns-bootstrap.sh          # idempotent dnsmasq + /etc/resolver setup
│   ├── cluster-up.sh
│   ├── cluster-down.sh
│   └── smoke-test.sh
├── cluster/
│   └── kind-config.yaml
└── helm/
    ├── cilium/values.yaml
    ├── cert-manager/values.yaml
    ├── gateway/gateway.yaml       # shared lab-gateway Gateway resource
    ├── dns/dnsmasq.yaml.tmpl      # templated with the Gateway's assigned IP
    ├── cluster-issuer/issuer.yaml.tmpl  # templated with step-ca host/port + CA bundle
    └── smoke-test/                # Deployment, Service, HTTPRoute, Certificate manifests
```

## Taskfile targets

- `task cluster:up` — full bootstrap; idempotent (if the `kind-lab` cluster already exists, skip creation and re-apply the Helm/manifest steps rather than erroring)
- `task cluster:down` — `kind delete cluster`
- `task cluster:status` — quick health check (nodes ready, Cilium ready, cert-manager ready, dnsmasq resolving)
- `task smoke:test` — re-run just the smoke-test verification

## Error handling

- Every script uses `set -euo pipefail`.
- `lib.sh` provides a `wait_for` helper (poll with timeout) used after each install step (Cilium ready, cert-manager rollout, Gateway LB IP assigned, dnsmasq ready, `Certificate` `Ready` condition), so failures surface at the step that caused them rather than as an opaque timeout later.
- `cluster:up` is safe to re-run: existing cluster/Helm releases are treated as no-ops, so recovering from a mid-bootstrap failure is just "run it again." The DNS step specifically re-templates and re-applies on every run since the Gateway's assigned IP can change across cluster recreations.

## Testing

There is no separate test suite for this sub-project — the smoke test *is* the test. Success is defined as: all pods ready, the shared Gateway has a LoadBalancer IP, `smoke.lab.test` resolves via the in-cluster dnsmasq (verify with a `getaddrinfo()`-based check, e.g. `python3 -c "import socket; print(socket.gethostbyname('smoke.lab.test'))"` — plain `dig` bypasses macOS's per-domain resolver mechanism and returns `NXDOMAIN` even when resolution is actually working, discovered during Task 8), the `Certificate` resource reaches `Ready`, and `curl --cacert <root_ca.crt>` (no `-k`) against `https://smoke.lab.test` returns HTTP 200 with a certificate chain that validates against the local root CA.

## Open items carried to later sub-projects

- Ingress vs. Gateway API is now decided (Gateway API, via Cilium) — no longer open.
- Whether a Forgejo Git server is needed for the promotion workflow — still open, deferred to the Kargo/promotion sub-project.
