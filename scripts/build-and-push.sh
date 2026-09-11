#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Builds the event-generator image, tags it with the current git short SHA,
# and pushes it to ghcr.io. Requires a prior `docker login ghcr.io` using a
# write:packages-scoped token (the user's own machine-level auth — this
# script never handles that credential itself, unlike registry-secret-up.sh
# which does take a token as input, because that one has to hand the
# credential *into* the cluster).
#
# Tagging by git short SHA (rather than something like `latest`) gives every
# build a unique, traceable identifier: you can always answer "which commit
# produced the image currently running in the cluster" by reading
# helm/event-generator/values.yaml's image.tag and looking that SHA up in
# `git log`. This is also exactly the kind of unambiguous, immutable
# version string Kargo (sub-project 3b) will need to promote a specific
# build from dev to "prod" rather than just re-pulling a mutable tag.

IMAGE="ghcr.io/tilraunastofan/kind-lab-argo-kargo-tekton/event-generator"
APP_DIR="${SCRIPT_DIR}/../demo-apps/event-generator"

main() {
  require_cmd docker git

  local tag
  tag="$(git -C "${SCRIPT_DIR}/.." rev-parse --short HEAD)"

  if ! git -C "${SCRIPT_DIR}/.." diff --quiet -- "${APP_DIR}" || ! git -C "${SCRIPT_DIR}/.." diff --cached --quiet -- "${APP_DIR}"; then
    warn "uncommitted changes under demo-apps/event-generator — the pushed image will not exactly match any commit"
  fi

  log "building ${IMAGE}:${tag}"
  docker build -t "${IMAGE}:${tag}" "${APP_DIR}"

  log "pushing ${IMAGE}:${tag} (requires prior 'docker login ghcr.io' with a write:packages-scoped token)"
  docker push "${IMAGE}:${tag}"

  log "pushed ${IMAGE}:${tag}"
  # Deliberately not automated: this script builds and publishes the
  # artifact, but does NOT edit values.yaml/commit/push itself — that
  # separation (build vs. deploy) is exactly the boundary Kargo will later
  # own end-to-end. Doing it manually once here, per the spec, is what
  # proves out the mechanism Kargo automates in sub-project 3b.
  log "next: set helm/event-generator/values.yaml image.tag to '${tag}', commit, and push to main"
}

main "$@"
