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
  local nets
  nets="$(docker inspect -f '{{json .NetworkSettings.Networks}}' "${CONTAINER}")"
  [[ "${nets}" == *"\"${NETWORK}\""* ]]
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
