#!/usr/bin/env bash
# Summarised status of the whole lab (cluster, GitOps, endpoints, host services).
# Read-only; never exits non-zero just because something is unhealthy.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CLUSTER_NAME="${CLUSTER_NAME:-tekton-lab}"
HOSTS=(argocd headlamp event-generator smoke pipelines-as-code)

ok()   { printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✘\033[0m %s\n' "$*"; }
meh()  { printf '  \033[1;33m-\033[0m %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

require_cmd kubectl docker kind curl

section "Cluster (${CLUSTER_NAME})"
if ! docker info >/dev/null 2>&1; then
  bad "Docker daemon is not running (start OrbStack/Docker first)"
  exit 0
fi
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  bad "kind cluster '${CLUSTER_NAME}' does not exist (run: task cluster:up)"
  section "Host services"
  if docker ps --format '{{.Names}}' | grep -qx clickhouse-logs; then
    ok "clickhouse-logs container running"
  else
    meh "clickhouse-logs container not running"
  fi
  exit 0
fi

KCTX="kind-${CLUSTER_NAME}"
k() { kubectl --context "${KCTX}" "$@"; }

if ! k get nodes >/dev/null 2>&1; then
  bad "cluster exists but API server is unreachable"
  exit 0
fi

total="$(k get nodes --no-headers | wc -l | tr -d ' ')"
ready="$(k get nodes --no-headers | awk '$2=="Ready"' | wc -l | tr -d ' ')"
if [ "${ready}" = "${total}" ]; then ok "nodes: ${ready}/${total} Ready"; else bad "nodes: ${ready}/${total} Ready"; fi

section "ArgoCD Applications"
apps="$(k -n argocd get applications --no-headers \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null)"
if [ -z "${apps}" ]; then
  meh "no Applications found"
else
  while read -r name sync health; do
    if [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]; then
      ok "${name}"
    else
      bad "${name}: sync=${sync} health=${health}"
    fi
  done <<< "${apps}"
fi

section "Pods not Running/Completed"
unhealthy="$(k get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded" {print "  "$1"/"$2" "$4" (restarts: "$5")"}')"
if [ -z "${unhealthy}" ]; then ok "all pods healthy"; else bad "unhealthy pods:"; echo "${unhealthy}"; fi

section "Certificates"
certs="$(k get certificates -A --no-headers 2>/dev/null)"
if [ -z "${certs}" ]; then
  meh "no Certificates found"
else
  while read -r ns name ready _; do
    if [ "${ready}" = "True" ]; then ok "${ns}/${name}"; else bad "${ns}/${name} not Ready"; fi
  done <<< "${certs}"
fi

section "Endpoints (HTTPS)"
for h in "${HOSTS[@]}"; do
  url="https://${h}.tekton-lab.test"
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${url}" 2>/dev/null || true)"
  case "${code}" in
    000|"") bad "${url} unreachable (DNS/TLS/connection)" ;;
    5*)     bad "${url} -> ${code}" ;;
    *)      ok  "${url} -> ${code}" ;;
  esac
done

section "Tekton / Pipelines-as-Code"
prs="$(k get pipelineruns -A --no-headers --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -3)"
if [ -z "${prs}" ]; then meh "no PipelineRuns yet"; else echo "  last PipelineRuns:"; echo "${prs}" | sed 's/^/    /'; fi

section "Host services"
if docker ps --format '{{.Names}}' | grep -qx clickhouse-logs; then
  ok "clickhouse-logs container running"
else
  bad "clickhouse-logs container not running (run: task logs-db:up)"
fi
if pgrep -f 'step-ca' >/dev/null 2>&1; then ok "step-ca running"; else bad "step-ca not running"; fi
echo
