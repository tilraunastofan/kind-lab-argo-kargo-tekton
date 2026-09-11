#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Creates/refreshes the datadog-secret Secret in the datadog namespace,
# which helm/datadog-agent's DatadogAgent custom resource
# (spec.global.credentials.apiSecret) references so the Node Agent and
# Cluster Agent can authenticate to Datadog's intake API. Requires
# DATADOG_API_KEY in the environment (not committed to Git — the README's
# Prerequisites section documents this as a required local env var the
# cluster is free to use directly).
#
# Why a plain kubectl-created Secret instead of a Helm-templated one (the
# way helm/clickhouse/templates/secret.yaml handles the ClickHouse admin
# password): a Datadog API key is a real credential to a third-party SaaS,
# not a lab-only default that's "fine to commit for a fully local
# cluster" — it must never end up in Git, so it can't live in any chart's
# values.yaml or stringData at all. This script creates it out-of-band,
# the exact same way registry-secret-up.sh creates the ghcr-pull
# imagePullSecret from GHCR_PULL_TOKEN.

main() {
  require_cmd kubectl

  if [ -z "${DATADOG_API_KEY:-}" ]; then
    die "DATADOG_API_KEY is not set — export your Datadog API key first"
  fi

  # Same idempotency trick as registry-secret-up.sh: `kubectl create`
  # rendered client-side (--dry-run=client — "print the YAML this would
  # create, don't talk to the apiserver") piped into `apply` creates on
  # the first run and updates in place (e.g. if the key ever rotates) on
  # every run after, instead of failing with "already exists" on a rerun.
  log "ensuring datadog namespace exists"
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing datadog-secret in datadog"
  kubectl -n datadog create secret generic datadog-secret \
    --from-literal=api-key="${DATADOG_API_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "datadog-secret ready in datadog"
}

main "$@"
