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
  # Expand ${tmp} now: it is local, so it is out of scope when EXIT fires.
  trap "rm -rf '${tmp}'" EXIT

  yq '.customConfig' "${REPO_ROOT}/helm/vector/values.yaml" > "${tmp}/vector.yaml"
  cp "${REPO_ROOT}/helm/vector/tests/pipeline-test.yaml" "${tmp}/pipeline-test.yaml"

  # The sink interpolates ${CLICKHOUSE_LOGS_VECTOR_PASSWORD}; Vector fails
  # config load if it's unset (and interpolation is off by default in 0.58, hence the opt-in env var), so give it a dummy value (nothing connects).
  local -a run=(docker run --rm -v "${tmp}:/cfg:ro" -e VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true -e CLICKHOUSE_LOGS_VECTOR_PASSWORD=dummy "${VECTOR_IMAGE}")

  log "vector test (VRL unit tests)"
  "${run[@]}" test /cfg/vector.yaml /cfg/pipeline-test.yaml

  log "vector validate (config only; no sources/sinks are contacted)"
  "${run[@]}" validate --no-environment /cfg/vector.yaml

  log "vector config OK"
}

main "$@"
