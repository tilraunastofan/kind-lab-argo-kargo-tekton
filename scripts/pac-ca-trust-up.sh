#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

FORGEJO_HOST_SSH="cm4.local"

# Creates/refreshes the pac-controller-ca-bundle ConfigMap in the
# pipelines-as-code namespace: a combined CA bundle the PAC controller and
# watcher Deployments mount and point SSL_CERT_FILE at (see
# vendor/pipelines-as-code/release.yaml). Both components call back into
# the Forgejo API (fetch .tekton/*.yaml, post commit statuses), and their
# minimal container images have no OS trust store to extend the way
# the Forgejo container itself does via update-ca-certificates (see
# scripts/pac-forgejo-trust-up.sh).
#
# Two custom CAs need to be trusted, discovered live during Task 6's
# end-to-end verification (kind-lab-pac-poc- PipelineRun and its watcher
# reconcile both failed with "x509: certificate signed by unknown
# authority" until both were added):
#   1. The step-ca root (~/.step/certs/root_ca.crt, already trusted by
#      this Mac and used throughout this repo for *.tekton-lab.test) — Forgejo's
#      webhook target, pipelines-as-code.tekton-lab.test, presents a cert chained
#      to this root.
#   2. Caddy's local CA root, fetched live via SSH from the Raspberry Pi
#      running Forgejo (git.local's own TLS is fronted by Caddy, which
#      auto-provisions a local (non-public) CA for internal hostnames like
#      git.local rather than a publicly-trusted one) — the PAC
#      controller/watcher call back into https://git.local, so this must
#      be trusted too.
#
# Since the target container images are minimal (no shell, no
# update-ca-certificates), SSL_CERT_FILE must point at a *complete* usable
# bundle, not just these two extra certs — Go's crypto/x509 uses only
# SSL_CERT_FILE's contents when it's set, it doesn't merge with a
# (nonexistent) system default. The Forgejo container's own
# /etc/ssl/certs/ca-certificates.crt (a full Debian-style bundle, already
# extended with the step-ca root by scripts/pac-forgejo-trust-up.sh) is
# reused as that base, fetched fresh each run so it stays in sync with
# whatever's actually trusted there.

tmpdir=""
cleanup() {
  [ -n "${tmpdir}" ] && rm -rf "${tmpdir}"
}
trap cleanup EXIT

main() {
  require_cmd kubectl ssh tar

  tmpdir="$(mktemp -d)"

  # `docker cp <container>:<path> -` writes a TAR STREAM to stdout, not
  # the raw file bytes (that's `docker cp`'s documented behavior whenever
  # the destination is `-`) — piping straight into a file produces a tar
  # header + padding wrapped around the real content, which Go's
  # crypto/x509 (and any strict PEM parser) silently fails to parse as
  # certificates. `tar -xO` un-wraps a single-file tar stream back to its
  # raw bytes on stdout without ever touching disk.
  log "fetching base CA bundle from the Forgejo container (already includes the step-ca root)"
  ssh "${FORGEJO_HOST_SSH}" "docker cp forgejo:/etc/ssl/certs/ca-certificates.crt -" | tar -xOf - > "${tmpdir}/base.crt" \
    || die "could not fetch /etc/ssl/certs/ca-certificates.crt from the forgejo container on ${FORGEJO_HOST_SSH} — run scripts/pac-forgejo-trust-up.sh first"

  log "fetching Caddy's local root CA from ${FORGEJO_HOST_SSH}"
  ssh "${FORGEJO_HOST_SSH}" "sudo -n cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt" > "${tmpdir}/caddy-root.crt" \
    || die "could not fetch Caddy's local root CA from ${FORGEJO_HOST_SSH} — check passwordless sudo is configured there"

  cat "${tmpdir}/base.crt" "${tmpdir}/caddy-root.crt" > "${tmpdir}/combined.crt"

  log "ensuring pipelines-as-code namespace exists"
  kubectl create namespace pipelines-as-code --dry-run=client -o yaml | kubectl apply -f -

  log "creating/refreshing pac-controller-ca-bundle in pipelines-as-code"
  kubectl -n pipelines-as-code create configmap pac-controller-ca-bundle \
    --from-file=ca-certificates.crt="${tmpdir}/combined.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "pac-controller-ca-bundle ready — restart the controller/watcher Deployments if this bundle's content changed:"
  log "  kubectl -n pipelines-as-code rollout restart deployment pipelines-as-code-controller pipelines-as-code-watcher"
}

main "$@"
