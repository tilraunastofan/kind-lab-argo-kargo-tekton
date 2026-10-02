#!/usr/bin/env bash
# Interactive kubectl helpers built on fzf. Usage: scripts/kfzf.sh <command>
# Runs against the current kubectl context. Cancelling a picker (Esc) is not an error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

namespaces() { kubectl get ns -o name | cut -d/ -f2; }
pods()       { kubectl get pods -A --no-headers; }

# List every namespaced resource in the picked namespace(s).
cmd_resources() {
  namespaces | fzf -m --preview 'kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl -n {} get --ignore-not-found --show-kind 2>/dev/null' --preview-window=right:70% \
    | while read -r ns; do
        echo "=== ${ns}"
        kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl -n "${ns}" get --ignore-not-found --show-kind
      done || true
}

# Set the default namespace of the current context.
cmd_ns() {
  local ns
  ns="$(namespaces | fzf)" || return 0
  kubectl config set-context --current --namespace="${ns}"
}

# Follow logs of a picked pod (all containers).
cmd_logs() {
  local row
  row="$(pods | fzf --preview 'kubectl -n {1} logs {2} --tail=30 --all-containers 2>&1')" || return 0
  # shellcheck disable=SC2086
  set -- ${row}
  kubectl -n "$1" logs -f --all-containers "$2"
}

# Shell into a picked pod.
cmd_exec() {
  local row
  row="$(pods | fzf)" || return 0
  # shellcheck disable=SC2086
  set -- ${row}
  kubectl -n "$1" exec -it "$2" -- sh
}

# Pick a resource type, then objects of it across all namespaces; prints "namespace name".
cmd_pick() {
  local r
  r="$(kubectl api-resources --verbs=list -o name | fzf)" || return 0
  kubectl get "${r}" -A --no-headers | fzf -m | awk '{print $1" "$2}' || true
}

# Pods that are not Running/Completed, with describe output as preview.
cmd_broken() {
  pods | { grep -v -E 'Running|Completed' || true; } \
    | fzf --preview 'kubectl -n {1} describe pod {2} | tail -25' || true
}

# Namespaces stuck in Terminating, and what is blocking them.
cmd_stuck() {
  local ns
  ns="$(kubectl get ns --no-headers | awk '$2=="Terminating"{print $1}' | fzf)" || return 0
  kubectl get ns "${ns}" -o jsonpath='{.status.conditions[?(@.type=="NamespaceFinalizersRemaining")].message}{"\n"}'
}

# Hard-refresh the picked ArgoCD Applications.
cmd_refresh() {
  kubectl -n argocd get applications --no-headers | fzf -m | awk '{print $1}' \
    | xargs -I{} kubectl -n argocd annotate application {} argocd.argoproj.io/refresh=hard --overwrite || true
}

# Delete picked secrets (previews key names, never values; asks before each delete).
cmd_secrets_delete() {
  kubectl get secrets -A --no-headers \
    | fzf -m --preview 'kubectl -n {1} get secret {2} -o jsonpath="{.data}" | python3 -c "import json,sys;print(list(json.load(sys.stdin)))"' \
    | awk '{print "-n "$1" secret "$2}' | xargs -L1 -p kubectl delete || true
}

usage() {
  cat <<U
Usage: scripts/kfzf.sh <command>
  resources        list all resources in picked namespace(s)
  ns               switch the current context's default namespace
  logs             follow logs of a picked pod
  exec             shell into a picked pod
  pick             pick a resource type, then objects; prints "namespace name"
  broken           pods not Running/Completed, with describe preview
  stuck            Terminating namespaces and their blocking finalizers
  refresh          hard-refresh picked ArgoCD Applications
  secrets-delete   delete picked secrets (confirms each)
U
}

main() {
  require_cmd kubectl fzf
  case "${1:-}" in
    resources) cmd_resources ;;
    ns) cmd_ns ;;
    logs) cmd_logs ;;
    exec) cmd_exec ;;
    pick) cmd_pick ;;
    broken) cmd_broken ;;
    stuck) cmd_stuck ;;
    refresh) cmd_refresh ;;
    secrets-delete) cmd_secrets_delete ;;
    *) usage; [ -z "${1:-}" ] || exit 1 ;;
  esac
}

main "$@"
