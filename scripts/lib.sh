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

CLUSTER_NAME="tekton-lab"
LAB_DOMAIN="tekton-lab.test"
STEPCA_PORT="9443"
