#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Runs (or repairs) the log-storage ClickStack on the Mac and applies the
# logs schema. The container is ClickStack's all-in-one image: a ClickHouse
# server (HTTP :8123, what Vector writes to) plus the ClickStack/HyperDX web
# UI (:8080), MongoDB for the UI's state, and an OTel collector. Safe to re-run any number of times; bootstrap.sh calls it on every
# `task cluster:up`.
#
# Why a container on the `kind` Docker network: kind's nodes are containers on
# that network, so pods (whose egress goes out through the node) resolve and
# reach `clickhouse-logs` by name, and OrbStack lets the Mac reach the same
# container by IP. One container serves Vector and `clickhouse-client` alike.
# The named volumes outlive the cluster, so logs survive `task cluster:down`.

CONTAINER="clickhouse-logs"
IMAGE="clickhouse/clickstack-all-in-one:2.39.1"
NETWORK="kind"
# Previous generation: plain clickhouse-server:26.9 with volume clickhouse-logs-data.
# Its data was written by ClickHouse 26.9 and ClickStack bundles 26.8 (a
# downgrade ClickHouse doesn't support), so the new volumes start empty and
# the old volume is left untouched.
VOLUME_CH="clickstack-ch-data"
VOLUME_MONGO="clickstack-mongo-data"
STATE_DIR="${HOME}/.local/state/tekton-lab/clickhouse-logs"
USERS_FILE="${STATE_DIR}/lab-users.xml"

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

# Renders users.xml.tmpl into the file mounted into the container. Rewritten
# IN PLACE (cat >), not replaced, so a running container's bind mount keeps
# seeing it and ClickHouse hot-reloads changed passwords.
render_users_file() {
  local admin_sha vector_sha
  admin_sha="$(printf %s "${CLICKHOUSE_LOGS_ADMIN_PASSWORD}" | shasum -a 256 | cut -d' ' -f1)"
  vector_sha="$(printf %s "${CLICKHOUSE_LOGS_VECTOR_PASSWORD}" | shasum -a 256 | cut -d' ' -f1)"
  mkdir -p "${STATE_DIR}"
  [ -e "${USERS_FILE}" ] || (umask 077 && : > "${USERS_FILE}")
  ADMIN_SHA256="${admin_sha}" VECTOR_SHA256="${vector_sha}" \
    envsubst '${ADMIN_SHA256} ${VECTOR_SHA256}' < "${SCRIPT_DIR}/clickhouse-logs/users.xml.tmpl" > "${USERS_FILE}"
}

main() {
  require_cmd docker envsubst openssl shasum

  ensure_token CLICKHOUSE_LOGS_ADMIN_PASSWORD
  ensure_token CLICKHOUSE_LOGS_VECTOR_PASSWORD

  docker network inspect "${NETWORK}" >/dev/null 2>&1 \
    || die "Docker network '${NETWORK}' not found — run 'task cluster:up' first (kind creates it)"

  render_users_file

  if docker inspect "${CONTAINER}" >/dev/null 2>&1 \
     && [ "$(docker inspect -f '{{.Config.Image}}' "${CONTAINER}")" != "${IMAGE}" ]; then
    warn "${CONTAINER} runs a different image than ${IMAGE}; recreating it (volumes are kept; the old clickhouse-logs-data volume is left as is)"
    docker rm -f "${CONTAINER}" >/dev/null
  fi

  if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
    log "container ${CONTAINER} exists"
    # After a cluster rebuild the container may have been detached from the
    # network; re-attach (idempotent) and make sure it is running.
    on_network || { log "re-attaching ${CONTAINER} to ${NETWORK}"; docker network connect "${NETWORK}" "${CONTAINER}"; }
    [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}")" = "true" ] || docker start "${CONTAINER}" >/dev/null
  else
    log "creating container ${CONTAINER} (${IMAGE})"
    # Only 127.0.0.1:8123 (ClickHouse HTTP) and 127.0.0.1:8080 (UI) are
    # published: pods and the Mac reach the container directly over the kind
    # network, so nothing needs to listen on the LAN. Users come from the
    # mounted users.d file (see render_users_file).
    docker run -d --name "${CONTAINER}" \
      --restart unless-stopped \
      --network "${NETWORK}" \
      --ulimit nofile=262144:262144 \
      -v "${VOLUME_CH}:/var/lib/clickhouse" \
      -v "${VOLUME_MONGO}:/data/db" \
      -v "${USERS_FILE}:/etc/clickhouse-server/users.d/lab-users.xml:ro" \
      -p 127.0.0.1:8123:8123 \
      -p 127.0.0.1:8080:8080 \
      "${IMAGE}" >/dev/null
  fi

  wait_for "clickhouse-logs accepting queries" 180 ch_query --query "SELECT 1"

  log "applying schema"
  ch_query --multiquery < "${SCRIPT_DIR}/clickhouse-logs/schema.sql"

  log "clickhouse-logs ready (network ${NETWORK}, http://clickhouse-logs:8123, Mac: http://127.0.0.1:8123, ClickStack UI: http://localhost:8080)"
}

main "$@"
