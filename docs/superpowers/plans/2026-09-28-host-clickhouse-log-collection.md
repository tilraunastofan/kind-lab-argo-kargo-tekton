# Host ClickHouse + Vector Log Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a ClickHouse server as a Docker container on the Mac and ship every container log from the `tekton-lab` kind cluster into it with a Vector DaemonSet.

**Architecture:** One `clickhouse-logs` container (OrbStack) attached to the `kind` Docker network, so pods reach it by container name and the Mac reaches it by IP. Vector (official Helm chart, Agent/DaemonSet role, installed via an ArgoCD Application) reads pod logs with `kubernetes_logs`, reshapes them with a VRL `remap`, and inserts into `logs.logs` as an insert-only `vector` user. Passwords are generated into `~/.tokens` and delivered to the cluster as a Kubernetes Secret.

**Tech Stack:** bash scripts (repo style, `scripts/lib.sh` helpers), Docker/OrbStack, ClickHouse `26.9`, Vector chart `0.58.0` (image `timberio/vector:0.58.0-distroless-libc`), ArgoCD, `yq`, `envsubst`.

**Spec:** `docs/superpowers/specs/2026-09-28-host-clickhouse-log-collection-design.md`

## Global Constraints

- Container name `clickhouse-logs`, volume `clickhouse-logs-data`, image `clickhouse/clickhouse-server:26.9`, Docker network `kind`, `--restart unless-stopped`, published `127.0.0.1:8123` only.
- Database/table `logs.logs`: MergeTree, `PARTITION BY toDate(timestamp)`, `ORDER BY (namespace, pod, timestamp)`, `TTL 14 days`.
- Columns: `timestamp`, `namespace`, `pod`, `container`, `node`, `stream`, `message`, `labels` (Map), `fields` (Map, parsed JSON).
- Users: `admin` (full) and `vector` (`GRANT INSERT ON logs.logs` only). Env vars `CLICKHOUSE_LOGS_ADMIN_PASSWORD` and `CLICKHOUSE_LOGS_VECTOR_PASSWORD`; auto-generated into `~/.tokens` when unset; never committed.
- Kubernetes: namespace `logging`, Secret `vector-clickhouse` (key `password`), Vector DaemonSet tolerates the control-plane `NoSchedule` taint, Vector's own pod is excluded from collection.
- ArgoCD apps live in `gitops/apps/` (root-app scans it non-recursively), charts' values in `helm/<name>/values.yaml`, repo URL `git@github.com:tilraunastofan/kind-lab-argo-kargo-tekton.git`, branch `main`.
- Code comments are more generous than a production repo (this is a learning lab). Scripts follow `set -euo pipefail`, `source lib.sh`, `log`/`die`/`require_cmd`/`wait_for`.
- Git commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- **Never push to `main` or tear the cluster down without asking the user first.**
- The local `ls` is aliased and rejects paths: use `command ls`.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib.sh` (modify) | add `ensure_token` |
| `scripts/tests/ensure-token-test.sh` (create) | tests for `ensure_token` |
| `scripts/clickhouse-logs/schema.sql` (create) | database, table, `vector` user + grant |
| `scripts/clickhouse-logs-up.sh` (create) | idempotent host container + schema |
| `Taskfile.yaml` (modify) | `logs-db:up`, `logs-db:down`, `logs-db:purge` |
| `helm/vector/values.yaml` (create) | Vector Agent config: source, VRL, sink, tolerations, env |
| `helm/vector/tests/pipeline-test.yaml` (create) | Vector unit tests for the VRL |
| `scripts/vector-config-test.sh` (create) | runs `vector test` + `vector validate` in Docker |
| `scripts/vector-secret-up.sh` (create) | `logging` ns + `vector-clickhouse` Secret |
| `gitops/apps/vector.yaml` (create) | ArgoCD Application |
| `bootstrap.sh` (modify) | wire both up-scripts |
| `README.md`, `CLAUDE.md` (modify) | document |

---

### Task 1: `ensure_token` helper (auto-generate secrets into `~/.tokens`)

**Files:**
- Modify: `scripts/lib.sh` (append after `wait_for`, before the `CLUSTER_NAME=` constants)
- Create: `scripts/tests/ensure-token-test.sh`

**Interfaces:**
- Produces: `ensure_token <VAR_NAME>` — call directly (NOT inside `$(...)`, it must `export` into the caller's shell). Resolution order: existing env var → last `export VAR=...` line in `$TOKENS_FILE` (default `$HOME/.tokens`) → generate `openssl rand -hex 24`, append `export VAR=<value>` to the file. Always ends with the var exported in the current shell. `TOKENS_FILE` env overrides the path (used by tests).

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/ensure-token-test.sh`:

```bash
#!/usr/bin/env bash
# Tests for ensure_token in scripts/lib.sh. Uses a throwaway TOKENS_FILE so it
# never touches the real ~/.tokens. Run: scripts/tests/ensure-token-test.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

# 1. Unset var + missing file: generates a 48-char hex value, exports it,
#    and appends an `export` line to the file.
(
  export TOKENS_FILE="${tmp}/t1"
  unset T_ONE || true
  ensure_token T_ONE
  [ "${#T_ONE}" -eq 48 ] || fail "1: expected 48 chars, got '${T_ONE}'"
  grep -q "^export T_ONE=${T_ONE}\$" "${TOKENS_FILE}" || fail "1: line not appended"
  echo "${T_ONE}" > "${tmp}/t1.value"
)

# 2. A fresh shell (var unset) reads the SAME value back from the file.
(
  export TOKENS_FILE="${tmp}/t1"
  unset T_ONE || true
  ensure_token T_ONE
  [ "${T_ONE}" = "$(cat "${tmp}/t1.value")" ] || fail "2: value changed on second run"
  [ "$(grep -c '^export T_ONE=' "${TOKENS_FILE}")" -eq 1 ] || fail "2: duplicate line appended"
)

# 3. Var already in the environment wins and the file is left untouched.
(
  export TOKENS_FILE="${tmp}/t3"
  export T_THREE="from-env"
  ensure_token T_THREE
  [ "${T_THREE}" = "from-env" ] || fail "3: env value overwritten"
  [ ! -e "${TOKENS_FILE}" ] || fail "3: file created although env was set"
)

# 4. Commented-out lines and quoted values are handled.
(
  export TOKENS_FILE="${tmp}/t4"
  printf '#export T_FOUR=commented\nexport T_FOUR="quoted"\n' > "${TOKENS_FILE}"
  unset T_FOUR || true
  ensure_token T_FOUR
  [ "${T_FOUR}" = "quoted" ] || fail "4: expected 'quoted', got '${T_FOUR}'"
)

echo "ensure-token-test: all passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x scripts/tests/ensure-token-test.sh && scripts/tests/ensure-token-test.sh`
Expected: FAIL with `ensure_token: command not found`.

- [ ] **Step 3: Implement**

In `scripts/lib.sh`, insert after the `wait_for` function:

```bash
# ensure_token <VAR_NAME>
#
# Makes sure VAR_NAME is set AND exported in the calling shell, generating and
# persisting a random value if it doesn't exist anywhere yet. Lookup order:
#   1. the environment (already exported by ~/.zshrc sourcing ~/.tokens),
#   2. the last `export VAR_NAME=...` line in $TOKENS_FILE (~/.tokens) — needed
#      because a value generated by an EARLIER script in this same bootstrap
#      run was appended to the file, but the parent shell that started
#      bootstrap.sh never re-sourced it,
#   3. otherwise generate `openssl rand -hex 24` and append it to the file.
# Call it directly, not inside $(...): it must export into the caller's shell.
TOKENS_FILE="${TOKENS_FILE:-${HOME}/.tokens}"
ensure_token() {
  local name="$1" value
  value="${!name:-}"

  if [ -z "${value}" ] && [ -f "${TOKENS_FILE}" ]; then
    # ^export anchors the match so a commented-out `#export X=` is ignored;
    # the second sed strips one pair of surrounding quotes if present.
    value="$(sed -n "s/^export ${name}=\(.*\)\$/\1/p" "${TOKENS_FILE}" | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
  fi

  if [ -z "${value}" ]; then
    value="$(openssl rand -hex 24)"
    printf '\n# generated by scripts/lib.sh ensure_token\nexport %s=%s\n' "${name}" "${value}" >> "${TOKENS_FILE}"
    log "generated ${name} and appended it to ${TOKENS_FILE}"
  fi

  export "${name}=${value}"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/tests/ensure-token-test.sh`
Expected: `ensure-token-test: all passed`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh scripts/tests/ensure-token-test.sh
git commit -m "feat: add ensure_token helper that auto-generates secrets into ~/.tokens

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Host ClickHouse container + schema

**Files:**
- Create: `scripts/clickhouse-logs/schema.sql`
- Create: `scripts/clickhouse-logs-up.sh`
- Modify: `Taskfile.yaml` (append tasks)
- Modify: `docs/superpowers/specs/2026-09-28-host-clickhouse-log-collection-design.md` (one-line correction, Step 6)

**Interfaces:**
- Consumes: `ensure_token`, `log`, `die`, `require_cmd`, `wait_for` from `scripts/lib.sh`.
- Produces: running container `clickhouse-logs` on network `kind`; env vars `CLICKHOUSE_LOGS_ADMIN_PASSWORD` / `CLICKHOUSE_LOGS_VECTOR_PASSWORD` present in `~/.tokens`; table `logs.logs`; user `vector` with `INSERT` on `logs.logs`. Task 3 relies on host name `clickhouse-logs`, port 8123, db/table `logs`/`logs`, user `vector`.
- The `kind` network must already exist (kind creates it). The script fails with a clear message if it doesn't — deliberately does NOT hand-create it, because kind expects to own that network's IPv6/MTU options. (This corrects the spec's "creates the network if missing"; Step 6 fixes the spec.)

- [ ] **Step 1: Write the schema**

Create `scripts/clickhouse-logs/schema.sql`:

```sql
-- Applied by scripts/clickhouse-logs-up.sh through `envsubst` (only the one
-- variable below is substituted) on EVERY run, so everything here must be
-- idempotent.

CREATE DATABASE IF NOT EXISTS logs;

CREATE TABLE IF NOT EXISTS logs.logs
(
    timestamp DateTime64(3, 'UTC'),
    namespace LowCardinality(String),
    pod       String,
    container LowCardinality(String),
    node      LowCardinality(String),
    stream    LowCardinality(String),
    message   String,
    labels    Map(String, String),
    -- Top-level keys of the log line when it is a JSON object, values
    -- stringified (nested objects/arrays as JSON text). Empty otherwise.
    fields    Map(String, String)
)
ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (namespace, pod, timestamp)
TTL toDateTime(timestamp) + INTERVAL 14 DAY;

-- Vector's identity: it can append rows to logs.logs and do nothing else.
-- CREATE USER IF NOT EXISTS + ALTER USER together give "create it, and keep
-- the password in sync with ~/.tokens if that ever changes".
CREATE USER IF NOT EXISTS vector IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_LOGS_VECTOR_PASSWORD}';
ALTER USER vector IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_LOGS_VECTOR_PASSWORD}';
GRANT INSERT ON logs.logs TO vector;
```

- [ ] **Step 2: Write the script**

Create `scripts/clickhouse-logs-up.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Runs (or repairs) the log-storage ClickHouse on the Mac and applies its
# schema. Safe to re-run any number of times; bootstrap.sh calls it on every
# `task cluster:up`.
#
# Why a container on the `kind` Docker network: kind's nodes are containers on
# that network, so pods (whose egress goes out through the node) resolve and
# reach `clickhouse-logs` by name, and OrbStack lets the Mac reach the same
# container by IP. One container serves Vector and `clickhouse-client` alike.
# The named volume outlives the cluster, so logs survive `task cluster:down`.

CONTAINER="clickhouse-logs"
VOLUME="clickhouse-logs-data"
IMAGE="clickhouse/clickhouse-server:26.9"
NETWORK="kind"

# Runs clickhouse-client inside the container as admin. A function (not a
# subshell string) so wait_for can call it via `until "$@"`.
ch_query() {
  docker exec -i "${CONTAINER}" clickhouse-client \
    --user admin --password "${CLICKHOUSE_LOGS_ADMIN_PASSWORD}" "$@"
}

on_network() {
  docker inspect -f '{{json .NetworkSettings.Networks}}' "${CONTAINER}" \
    | grep -q "\"${NETWORK}\""
}

main() {
  require_cmd docker envsubst openssl

  ensure_token CLICKHOUSE_LOGS_ADMIN_PASSWORD
  ensure_token CLICKHOUSE_LOGS_VECTOR_PASSWORD

  docker network inspect "${NETWORK}" >/dev/null 2>&1 \
    || die "Docker network '${NETWORK}' not found — run 'task cluster:up' first (kind creates it)"

  if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
    log "container ${CONTAINER} exists"
    # After a cluster rebuild the container may have been detached from the
    # network; re-attach (idempotent) and make sure it is running.
    on_network || { log "re-attaching ${CONTAINER} to ${NETWORK}"; docker network connect "${NETWORK}" "${CONTAINER}"; }
    [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}")" = "true" ] || docker start "${CONTAINER}" >/dev/null
  else
    log "creating container ${CONTAINER} (${IMAGE})"
    # CLICKHOUSE_USER replaces the passwordless `default` user with `admin`.
    # DEFAULT_ACCESS_MANAGEMENT lets admin CREATE USER/GRANT (schema.sql).
    # Only 127.0.0.1:8123 is published: pods and the Mac reach the container
    # directly over the kind network, so nothing needs to listen on the LAN.
    docker run -d --name "${CONTAINER}" \
      --restart unless-stopped \
      --network "${NETWORK}" \
      --ulimit nofile=262144:262144 \
      -v "${VOLUME}:/var/lib/clickhouse" \
      -p 127.0.0.1:8123:8123 \
      -e CLICKHOUSE_USER=admin \
      -e CLICKHOUSE_PASSWORD="${CLICKHOUSE_LOGS_ADMIN_PASSWORD}" \
      -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
      "${IMAGE}" >/dev/null
  fi

  wait_for "clickhouse-logs accepting queries" 90 ch_query --query "SELECT 1"

  log "applying schema"
  # Restrict envsubst to the one variable so any `$` in the SQL is untouched.
  envsubst '${CLICKHOUSE_LOGS_VECTOR_PASSWORD}' < "${SCRIPT_DIR}/clickhouse-logs/schema.sql" \
    | ch_query --multiquery

  log "clickhouse-logs ready (network ${NETWORK}, http://clickhouse-logs:8123, Mac: http://127.0.0.1:8123)"
}

main "$@"
```

- [ ] **Step 3: Run it and verify**

Prereq: OrbStack running and the `tekton-lab` cluster up (the `kind` network exists).

Run: `chmod +x scripts/clickhouse-logs-up.sh && scripts/clickhouse-logs-up.sh`
Expected: ends with `clickhouse-logs ready ...`; `~/.tokens` now contains two new `export CLICKHOUSE_LOGS_*_PASSWORD=` lines.

Then verify each claim (source the passwords first: `source ~/.tokens`):

```bash
# a) table exists with 14-day TTL
docker exec clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" \
  --query "SHOW CREATE TABLE logs.logs" | grep -E "TTL|PARTITION BY|ORDER BY"

# b) vector can INSERT
docker exec clickhouse-logs clickhouse-client --user vector --password "$CLICKHOUSE_LOGS_VECTOR_PASSWORD" \
  --query "INSERT INTO logs.logs (timestamp,namespace,pod,container,node,stream,message) VALUES (now64(3),'t','t','t','t','stdout','hello')"

# c) vector can NOT read: expect "ACCESS_DENIED" / code 497
docker exec clickhouse-logs clickhouse-client --user vector --password "$CLICKHOUSE_LOGS_VECTOR_PASSWORD" \
  --query "SELECT count() FROM logs.logs" 2>&1 | grep -i -E "ACCESS_DENIED|497"

# d) admin sees the row, then clean it up
docker exec clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" \
  --query "SELECT message FROM logs.logs WHERE namespace='t'"
docker exec clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" \
  --query "ALTER TABLE logs.logs DELETE WHERE namespace='t'"

# e) reachable BY NAME from a node (IPv4 or IPv6) and from a pod, and by IP from the Mac
docker exec tekton-lab-worker bash -c 'exec 3<>/dev/tcp/clickhouse-logs/8123 && printf "GET /ping HTTP/1.0\r\n\r\n" >&3 && tail -1 <&3'   # Ok.
kubectl run ch-probe --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- http://clickhouse-logs:8123/ping   # Ok.
curl -s "http://$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' clickhouse-logs):8123/ping"    # Ok.
curl -s http://127.0.0.1:8123/ping                                                                                # Ok.
```

Expected: (a) shows `PARTITION BY toDate(timestamp)`, `ORDER BY (namespace, pod, timestamp)`, TTL 14 DAY; (b) no error; (c) matches; (d) prints `hello`; (e) four `Ok.` lines. If (e)'s node or pod check fails on an IPv6-first resolution, ClickHouse isn't listening on `::` — stop and report; do not work around it.

- [ ] **Step 4: Verify idempotency and re-attach**

```bash
scripts/clickhouse-logs-up.sh                       # 2nd run: "container exists", no errors, no new ~/.tokens lines
[ "$(grep -c '^export CLICKHOUSE_LOGS_' ~/.tokens)" -eq 2 ] && echo tokens-stable
docker network disconnect kind clickhouse-logs
scripts/clickhouse-logs-up.sh                       # logs "re-attaching clickhouse-logs to kind"
docker exec tekton-lab-worker bash -c 'getent hosts clickhouse-logs'   # resolves again
```

Expected: `tokens-stable`, the re-attach log line, and name resolution restored.

- [ ] **Step 5: Add Taskfile tasks**

Append to `Taskfile.yaml` (same 2-space indent under `tasks:`):

```yaml
  logs-db:up:
    desc: Start/repair the host ClickHouse container that stores cluster logs (needs the kind network)
    cmds:
      - ./scripts/clickhouse-logs-up.sh

  logs-db:down:
    desc: Remove the clickhouse-logs container (keeps its data volume; use logs-db:purge to delete data)
    cmds:
      - docker rm -f clickhouse-logs

  logs-db:purge:
    desc: DELETE all stored logs — removes the clickhouse-logs container and its data volume
    cmds:
      - docker rm -f clickhouse-logs
      - docker volume rm clickhouse-logs-data
```

Verify: `task --list | grep logs-db` shows three tasks. (Do not run `logs-db:down`/`purge` now.)

- [ ] **Step 6: Correct the spec**

In `docs/superpowers/specs/2026-09-28-host-clickhouse-log-collection-design.md`, in "Host side", replace the bullet beginning `- Creates the \`kind\` network if missing and re-runs` with:

```markdown
- Requires the `kind` network to already exist (kind creates it; the script
  fails with a clear message otherwise rather than hand-creating a network
  kind expects to own) and idempotently re-runs
  `docker network connect kind clickhouse-logs` (covers the unverified
  teardown case). An attached container also keeps kind from deleting the
  network.
```

- [ ] **Step 7: Commit**

```bash
git add scripts/clickhouse-logs scripts/clickhouse-logs-up.sh Taskfile.yaml docs/superpowers/specs/2026-09-28-host-clickhouse-log-collection-design.md
git commit -m "feat: run host ClickHouse container for cluster logs

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Vector DaemonSet → ClickHouse (ArgoCD app, VRL with unit tests, Secret script)

**Files:**
- Create: `helm/vector/tests/pipeline-test.yaml`
- Create: `scripts/vector-config-test.sh`
- Create: `helm/vector/values.yaml`
- Create: `scripts/vector-secret-up.sh`
- Create: `gitops/apps/vector.yaml`

**Interfaces:**
- Consumes: host `clickhouse-logs:8123`, db/table `logs.logs`, user `vector`, env `CLICKHOUSE_LOGS_VECTOR_PASSWORD` (Task 2); `ensure_token` (Task 1).
- Produces: Secret `vector-clickhouse` (key `password`) in namespace `logging`; ArgoCD Application `vector`; Vector transform named `shape` (unit-tested) and sink `clickhouse`.

- [ ] **Step 1: Write the failing unit tests**

Create `helm/vector/tests/pipeline-test.yaml`:

```yaml
# Unit tests for the `shape` remap transform in helm/vector/values.yaml.
# Run with scripts/vector-config-test.sh (extracts customConfig and calls
# `vector test`). Events are inserted where kubernetes_logs would emit them.
tests:
  - name: plain text line is flattened into the table columns
    inputs:
      - insert_at: shape
        type: log
        log_fields:
          message: "hello world"
          stream: stdout
          kubernetes.pod_namespace: kube-system
          kubernetes.pod_name: coredns-abc
          kubernetes.container_name: coredns
          kubernetes.pod_node_name: tekton-lab-worker
          kubernetes.pod_labels.k8s-app: kube-dns
    outputs:
      - extract_from: shape
        conditions:
          - type: vrl
            source: |
              assert_eq!(.namespace, "kube-system")
              assert_eq!(.pod, "coredns-abc")
              assert_eq!(.container, "coredns")
              assert_eq!(.node, "tekton-lab-worker")
              assert_eq!(.stream, "stdout")
              assert_eq!(.message, "hello world")
              assert_eq!(.labels, {"k8s-app": "kube-dns"})
              assert_eq!(.fields, {})
              assert!(!exists(.kubernetes))

  - name: JSON line becomes a Map of stringified top-level fields
    inputs:
      - insert_at: shape
        type: log
        log_fields:
          message: '{"level":"info","count":3,"nested":{"a":1}}'
          stream: stderr
          kubernetes.pod_namespace: demo
          kubernetes.pod_name: event-generator-1
          kubernetes.container_name: app
          kubernetes.pod_node_name: tekton-lab-worker2
    outputs:
      - extract_from: shape
        conditions:
          - type: vrl
            source: |
              assert_eq!(.fields.level, "info")
              assert_eq!(.fields.count, "3")
              assert_eq!(.fields.nested, "{\"a\":1}")
              assert_eq!(.message, "{\"level\":\"info\",\"count\":3,\"nested\":{\"a\":1}}")

  - name: malformed JSON-looking line does not fail; fields stay empty
    inputs:
      - insert_at: shape
        type: log
        log_fields:
          message: "{not json"
          stream: stdout
          kubernetes.pod_namespace: demo
          kubernetes.pod_name: p
          kubernetes.container_name: c
          kubernetes.pod_node_name: n
    outputs:
      - extract_from: shape
        conditions:
          - type: vrl
            source: |
              assert_eq!(.fields, {})
              assert_eq!(.message, "{not json")
```

Create `scripts/vector-config-test.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Unit-tests and validates the Vector pipeline in helm/vector/values.yaml
# without a cluster. The pipeline lives under `customConfig:` in the chart's
# values (that is where the Helm chart reads it from), so we extract that
# block with yq into a standalone Vector config and run the same Vector
# image the chart deploys. Keep VECTOR_IMAGE in sync with the chart's appVersion.
VECTOR_IMAGE="timberio/vector:0.58.0-distroless-libc"

main() {
  require_cmd docker yq

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  yq '.customConfig' "${REPO_ROOT}/helm/vector/values.yaml" > "${tmp}/vector.yaml"
  cp "${REPO_ROOT}/helm/vector/tests/pipeline-test.yaml" "${tmp}/pipeline-test.yaml"

  # The sink interpolates ${CLICKHOUSE_LOGS_VECTOR_PASSWORD}; Vector fails
  # config load if it's unset, so give it a dummy value (nothing connects).
  local -a run=(docker run --rm -v "${tmp}:/cfg:ro" -e CLICKHOUSE_LOGS_VECTOR_PASSWORD=dummy "${VECTOR_IMAGE}")

  log "vector test (VRL unit tests)"
  "${run[@]}" test /cfg/vector.yaml /cfg/pipeline-test.yaml

  log "vector validate (config only; no sources/sinks are contacted)"
  "${run[@]}" validate --no-environment /cfg/vector.yaml

  log "vector config OK"
}

main "$@"
```

- [ ] **Step 2: Run to verify it fails**

Run: `chmod +x scripts/vector-config-test.sh && scripts/vector-config-test.sh`
Expected: FAIL — `helm/vector/values.yaml` does not exist (yq error).

- [ ] **Step 3: Implement the Vector values**

Create `helm/vector/values.yaml`:

```yaml
# helm/vector/values.yaml — values for the official Vector chart
# (https://helm.vector.dev, chart `vector`), installed by
# gitops/apps/vector.yaml into the `logging` namespace.
#
# Vector runs as a DaemonSet ("Agent" role): one pod per node reads that
# node's container log files (/var/log/pods/...), enriches each line with
# Kubernetes metadata, reshapes it to the columns of logs.logs, and inserts
# it into the ClickHouse container that runs on the Mac (see
# scripts/clickhouse-logs-up.sh and
# docs/superpowers/specs/2026-09-28-host-clickhouse-log-collection-design.md).
role: Agent

# The control-plane node carries a NoSchedule taint; without this toleration
# the DaemonSet skips it and that node's logs (kube-apiserver, etcd, ...)
# would silently be missing — but the goal is ALL cluster logs.
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

# Password for the insert-only `vector` ClickHouse user. The Secret is created
# out-of-band by scripts/vector-secret-up.sh (it comes from ~/.tokens and must
# never live in Git). Vector interpolates ${CLICKHOUSE_LOGS_VECTOR_PASSWORD}
# in the config below at startup.
env:
  - name: CLICKHOUSE_LOGS_VECTOR_PASSWORD
    valueFrom:
      secretKeyRef:
        name: vector-clickhouse
        key: password

# The pipeline. scripts/vector-config-test.sh extracts THIS block (yq
# '.customConfig') to unit-test and validate it — helm/vector/tests/.
customConfig:
  data_dir: /vector-data-dir
  api:
    enabled: false

  sources:
    k8s:
      type: kubernetes_logs
      # Don't ship Vector's own logs: shipping them creates a feedback loop
      # (every insert error would be logged, collected, and inserted again).
      # Log files live under /var/log/pods/<namespace>_<pod>_<uid>/.
      exclude_paths_glob_patterns:
        - "/var/log/pods/logging_vector-*/**"

  transforms:
    # Reshape a kubernetes_logs event into exactly the columns of logs.logs.
    shape:
      type: remap
      inputs: [k8s]
      source: |
        # `?? ""` = "if the field is missing or the wrong type, use empty
        # string" — one odd event must never fail the whole remap.
        .namespace = string(.kubernetes.pod_namespace) ?? ""
        .pod = string(.kubernetes.pod_name) ?? ""
        .container = string(.kubernetes.container_name) ?? ""
        .node = string(.kubernetes.pod_node_name) ?? ""
        .stream = string(.stream) ?? ""
        .message = string(.message) ?? ""

        # Map(String,String) column: stringify every label value.
        labels = object(.kubernetes.pod_labels) ?? {}
        .labels = map_values(labels) -> |v| { to_string(v) ?? "" }

        # Structured (JSON-object) log lines: keep the raw line in `message`
        # AND expose the top-level keys as a queryable Map. Strings stay as-is,
        # anything else (numbers, nested objects, arrays) becomes JSON text.
        # The starts_with guard avoids attempting a parse on ordinary text;
        # parse errors are swallowed and simply leave `fields` empty.
        fields = {}
        if starts_with(.message, "{") {
          parsed, err = parse_json(.message)
          if err == null && is_object(parsed) {
            fields = map_values(object!(parsed)) -> |v| { string(v) ?? encode_json(v) }
          }
        }
        .fields = fields

        # Drop the source's bulky metadata; ClickHouse would ignore it anyway
        # (skip_unknown_fields below) but there is no reason to serialize it.
        del(.kubernetes)
        del(.file)
        del(.source_type)

  sinks:
    clickhouse:
      type: clickhouse
      inputs: [shape]
      # Container name on the `kind` Docker network (pods resolve it through
      # CoreDNS -> the node's Docker DNS).
      endpoint: http://clickhouse-logs:8123
      database: logs
      table: logs
      auth:
        strategy: basic
        user: vector
        password: "${CLICKHOUSE_LOGS_VECTOR_PASSWORD}"
      # The event carries only the table's columns after `shape`, but be
      # tolerant of anything extra rather than failing a whole batch.
      skip_unknown_fields: true
      # Vector emits RFC 3339 timestamps; this lets ClickHouse parse them into
      # the DateTime64 column.
      date_time_best_effort: true
      batch:
        timeout_secs: 5
        max_events: 5000
      # Default buffer is a small in-memory one with backpressure
      # (when_full: block): if ClickHouse is down Vector stops reading and
      # resumes from its checkpoint (data_dir) once it is back. Lines rotated
      # away during a long outage are lost — acceptable for a lab.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/vector-config-test.sh`
Expected: three tests `passed` (`test result: ok`), `vector validate` prints `Validated`, then `vector config OK`.

If a VRL compile error appears (e.g. closure syntax), fix `helm/vector/values.yaml` and re-run — the test file is the spec of behavior and should not be weakened. If `vector test` cannot load a `kubernetes_logs` source outside a cluster, change only the script (extract `.customConfig` and drop the source with `yq 'del(.sources)'` for the test run, keeping `validate` on the full file if it works, otherwise skip validate and say so).

- [ ] **Step 5: Write the Secret script**

Create `scripts/vector-secret-up.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the vector-clickhouse Secret in the logging namespace,
# which helm/vector/values.yaml maps into Vector's env as
# CLICKHOUSE_LOGS_VECTOR_PASSWORD. Same out-of-band, idempotent pattern as
# datadog-secret-up.sh: the value comes from ~/.tokens (auto-generated by
# ensure_token, shared with clickhouse-logs-up.sh which creates the matching
# ClickHouse user) and must never end up in Git.

main() {
  require_cmd kubectl openssl

  ensure_token CLICKHOUSE_LOGS_VECTOR_PASSWORD

  log "ensuring logging namespace exists"
  kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing vector-clickhouse in logging"
  kubectl -n logging create secret generic vector-clickhouse \
    --from-literal=password="${CLICKHOUSE_LOGS_VECTOR_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "vector-clickhouse ready in logging"
}

main "$@"
```

Run: `chmod +x scripts/vector-secret-up.sh && scripts/vector-secret-up.sh && scripts/vector-secret-up.sh`
Expected: both runs succeed; `kubectl -n logging get secret vector-clickhouse -o jsonpath='{.data.password}' | base64 -d` equals `$CLICKHOUSE_LOGS_VECTOR_PASSWORD` (after `source ~/.tokens`).

- [ ] **Step 6: Write the ArgoCD Application**

Create `gitops/apps/vector.yaml`:

```yaml
# gitops/apps/vector.yaml
#
# Installs Vector (https://vector.dev) as a DaemonSet that ships every
# container log in the cluster to the ClickHouse container running on the Mac
# (scripts/clickhouse-logs-up.sh). Chart values, including the whole pipeline,
# live in helm/vector/values.yaml. The vector-clickhouse Secret it needs is
# created by scripts/vector-secret-up.sh (bootstrap.sh runs it before ArgoCD
# gets here), so no sync-wave is needed — until the Secret exists the pods
# simply wait in CreateContainerConfigError.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vector
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://helm.vector.dev
      chart: vector
      targetRevision: 0.58.0
      helm:
        valueFiles:
          - $values/helm/vector/values.yaml
    - repoURL: git@github.com:tilraunastofan/kind-lab-argo-kargo-tekton.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 2m
```

- [ ] **Step 7: Commit**

```bash
git add helm/vector scripts/vector-config-test.sh scripts/vector-secret-up.sh gitops/apps/vector.yaml
git commit -m "feat: add Vector DaemonSet shipping cluster logs to host ClickHouse

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Deploy to the running cluster and verify logs land**

ArgoCD reads from GitHub `main` over SSH, so the change must be pushed. **Ask the user before pushing.** After they approve: `git push origin main`.

Then (with `source ~/.tokens`; Task 2's container and the Secret from Step 5 already exist):

```bash
kubectl -n argocd annotate application root-app argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get application vector -w          # wait for Synced / Healthy (Ctrl-C when done)
kubectl -n logging get pods -o wide                   # one vector pod per node, INCLUDING the control-plane node (3 total)
kubectl -n logging logs daemonset/vector --tail=20    # no auth/connection errors
```

Verify rows and coverage (wait ~30s):

```bash
ch() { docker exec clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" "$@"; }
ch --query "SELECT namespace, count() c FROM logs.logs GROUP BY namespace ORDER BY c DESC"
ch --query "SELECT DISTINCT node FROM logs.logs"                                   # all 3 nodes, incl. tekton-lab-control-plane
ch --query "SELECT count() FROM logs.logs WHERE namespace='logging'"               # 0: Vector's own logs excluded
ch --query "SELECT pod, fields FROM logs.logs WHERE length(fields) > 0 LIMIT 3"    # parsed JSON lines
```

Expected: `kube-system`, `argocd`, `ingress-nginx` (and others) present; three distinct nodes; `0` rows for `logging`; some rows with non-empty `fields`.

Failure/recovery check:

```bash
ch --query "SELECT count() FROM logs.logs"           # note N1
docker stop clickhouse-logs && sleep 30
kubectl -n logging get pods                           # vector pods still Running, restarts unchanged
docker start clickhouse-logs && sleep 30
ch --query "SELECT count() FROM logs.logs"           # > N1: ingestion resumed
```

If Vector logs a permission error mentioning `system.columns` / `DESCRIBE` for the `vector` user, the sink introspects the schema: add `GRANT SELECT ON system.columns TO vector;` to `scripts/clickhouse-logs-up.sh`'s schema (it exposes column metadata only, not log rows), re-run the script, and note it in the spec. Do not grant `SELECT` on `logs.logs`.

---

### Task 4: Wire into `bootstrap.sh` and document

**Files:**
- Modify: `bootstrap.sh`
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: `scripts/clickhouse-logs-up.sh`, `scripts/vector-secret-up.sh` (Tasks 2–3).

- [ ] **Step 1: Wire the scripts into `bootstrap.sh`**

After the line `"${SCRIPT_DIR}/cluster-up.sh"` add:

```bash
  # The log-storage ClickHouse (a plain Docker container on the Mac, attached
  # to kind's Docker network) — see scripts/clickhouse-logs-up.sh. Must run
  # AFTER cluster-up.sh because the `kind` network only exists once kind has
  # created the cluster, and it re-attaches the container to that network on
  # every rebuild. Independent of ArgoCD, so it can run this early.
  "${SCRIPT_DIR}/clickhouse-logs-up.sh"
```

After the line `"${SCRIPT_DIR}/datadog-secret-up.sh"` (and its comment) add:

```bash
  # Same reasoning as datadog-secret-up.sh: kubectl-only, and placed before
  # ArgoCD syncs gitops/apps/vector.yaml so the vector-clickhouse Secret
  # exists when Vector's pods first start. Reads the password that
  # clickhouse-logs-up.sh generated into ~/.tokens (via ensure_token).
  "${SCRIPT_DIR}/vector-secret-up.sh"
```

Verify: `bash -n bootstrap.sh && grep -n -E "clickhouse-logs-up|vector-secret-up" bootstrap.sh` shows both, with `clickhouse-logs-up.sh` after `cluster-up.sh` and `vector-secret-up.sh` after `argocd-up.sh`.

- [ ] **Step 2: Document in README.md**

Read `README.md` first (its `## Usage` section at ~line 62 and Prerequisites). Add, matching its tone, a `### Log collection (Vector → host ClickHouse)` subsection under Usage covering: what runs where (container `clickhouse-logs` on the Mac, Vector DaemonSet in `logging`); `task logs-db:up|down|purge`; passwords auto-generated into `~/.tokens` (`CLICKHOUSE_LOGS_ADMIN_PASSWORD`, `CLICKHOUSE_LOGS_VECTOR_PASSWORD`); how to query:

```bash
source ~/.tokens
docker exec -it clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" \
  --query "SELECT timestamp, namespace, pod, message FROM logs.logs ORDER BY timestamp DESC LIMIT 20"
# or over HTTP from the Mac: curl 'http://127.0.0.1:8123/?user=admin&password=...' --data 'SELECT ...'
```

and the 14-day TTL, the data volume surviving `cluster:down`, and the future Datadog→Vector→ClickHouse path (link to the spec).

- [ ] **Step 3: Document in CLAUDE.md**

Add a "Sub-project 6, log collection" paragraph in the style of the existing ones (after the `cloud-provider-kind` removal section): what was built and where (files from the File Structure table), the design facts that aren't obvious from code (kind-network attachment and why; insert-only user; passwords auto-generated by `ensure_token`; Vector excludes its own pod; control-plane toleration; `kind` network must pre-exist), the verification status **as actually performed** (fill in honestly after Task 5; until then say "verified against the running cluster, cold rebuild pending"), and that Datadog is still disabled but the `datadog_agent` source makes a Datadog→Vector→ClickHouse test possible.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh README.md CLAUDE.md
git commit -m "feat: wire log collection into bootstrap and document it

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Cold-rebuild verification (the bar earlier sub-projects were held to)

**Files:**
- Modify: `CLAUDE.md` (record the true outcome)

**This tears down the cluster. Ask the user for explicit go-ahead first, and push Task 4 to `main` first (ArgoCD reads `main`).**

- [ ] **Step 1: Seed a canary row so we can prove the volume survives**

```bash
source ~/.tokens
docker exec clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" \
  --query "INSERT INTO logs.logs (timestamp,namespace,pod,container,node,stream,message) VALUES (now64(3),'canary','c','c','c','stdout','survives-rebuild')"
```

- [ ] **Step 2: Tear down and rebuild**

```bash
task cluster:down
docker network inspect kind >/dev/null 2>&1 && echo "kind network still exists" || echo "kind network removed"   # RECORD which — resolves the spec's open question
docker inspect -f '{{json .NetworkSettings.Networks}}' clickhouse-logs                                        # RECORD: still attached?
task cluster:up
```

Expected: `task cluster:up` completes; `clickhouse-logs-up.sh` logs either nothing special or "re-attaching"; no manual steps required.

- [ ] **Step 3: Verify end to end**

```bash
source ~/.tokens
ch() { docker exec clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD" "$@"; }
kubectl -n argocd get applications                       # all Synced/Healthy, incl. vector
kubectl -n logging get pods -o wide                      # 3 vector pods Running
ch --query "SELECT message FROM logs.logs WHERE namespace='canary'"    # survives-rebuild (volume survived)
sleep 60
ch --query "SELECT namespace, count() FROM logs.logs WHERE timestamp > now() - INTERVAL 5 MINUTE GROUP BY namespace ORDER BY 2 DESC"   # fresh rows from the NEW cluster
```

Then clean up: `ch --query "ALTER TABLE logs.logs DELETE WHERE namespace='canary'"`.

- [ ] **Step 4: Record the outcome and commit**

Update the Sub-project 6 paragraph in `CLAUDE.md` with what actually happened (whether the `kind` network was removed/detached on teardown, any bugs found and fixed). Also update the spec's "Still unverified" bullet to the observed result.

```bash
git add CLAUDE.md docs/superpowers/specs/2026-09-28-host-clickhouse-log-collection-design.md
git commit -m "docs: record cold-rebuild verification of host ClickHouse log collection

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage**
- Decision 1 (Docker container, OrbStack, kind network, volume, restart policy, 127.0.0.1:8123): Task 2.
- Decision 2 (Vector DaemonSet, `kubernetes_logs`, clickhouse sink): Task 3.
- Decision 3 (flat table, columns, partition/order/TTL, Map for JSON): Task 2 schema + Task 3 VRL/tests.
- Decision 4 (insert-only user, `~/.tokens` auto-generation, Secret script): Tasks 1, 2, 3.
- Control-plane toleration, own-pod exclusion, backpressure/failure behavior: Task 3 (config + Step 8 failure check).
- Re-attach on rebuild, "kind network unverified" question: Task 2 Step 4, Task 5 Step 2.
- `logs-db:up/down` (+ purge), bootstrap wiring, README/CLAUDE.md: Tasks 2, 4.
- Verification bar (cold rebuild, namespaces incl. `kube-system`, insert-only proof, outage recovery): Tasks 2, 3, 5.
- Deviation from the spec (do not create the `kind` network): flagged and the spec corrected in Task 2 Step 6.
- Datadog→Vector→ClickHouse: explicitly future work (docs only).

**Placeholders:** none; the only conditional guidance (schema-introspection grant, `vector test` limitations) is in-task, with the exact remedy.

**Consistency:** names used identically across tasks — `clickhouse-logs`, `clickhouse-logs-data`, `kind`, `logs.logs`, `vector`, `vector-clickhouse`/`password`, `CLICKHOUSE_LOGS_ADMIN_PASSWORD`/`CLICKHOUSE_LOGS_VECTOR_PASSWORD`, transform `shape`, sink `clickhouse`, `ensure_token`.
