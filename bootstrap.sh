#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ingress_has_ip() {
  local ip
  ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "${ip}" ]
}

main() {
  require_cmd kind helm kubectl docker step step-ca go curl openssl security launchctl scutil envsubst ssh-keygen gh htpasswd

  "${SCRIPT_DIR}/stepca-bootstrap.sh"
  "${SCRIPT_DIR}/cloudprovider-bootstrap.sh"
  "${SCRIPT_DIR}/cluster-up.sh"
  # The three kargo-*-up.sh scripts run here, BEFORE argocd-up.sh, and
  # deliberately NOT grouped with datadog-secret-up.sh/registry-secret-up.sh
  # below (which only need kubectl too, but are harmless to run either side
  # of root-app.yaml being applied). These three are different: argocd-up.sh
  # applies gitops/root-app.yaml, which is what makes ArgoCD start syncing
  # gitops/apps/kargo-project.yaml — and that Application has
  # CreateNamespace=true against the "kind-lab" namespace. If ArgoCD creates
  # that namespace itself (unlabeled) before these scripts run, Kargo's
  # Project admission webhook rejects every Project/Warehouse/Stage in it
  # ("namespace is not a project" — see kargo-deploy-key-up.sh's and
  # kargo-image-cred-up.sh's kargo.akuity.io/project=true comments), and
  # ArgoCD's retry budget on that Application (5 attempts, 10s backoff
  # doubling to a 2m cap — ~2.5 total minutes) is not guaranteed to outlast
  # however long it takes bootstrap.sh to get here in every environment.
  # Running these three first, before root-app.yaml ever exists, guarantees
  # kind-lab is labeled and both credential Secrets already exist by the
  # time kargo-project's very first sync attempt happens — no dependency on
  # ArgoCD's sync-wave/retry timing at all. kargo-admin-up.sh matters too:
  # without it, kargo-api's Pod crash-loops indefinitely (argocd-up.sh's own
  # wait_for below only checks sync.status, not health.status, so it
  # wouldn't catch this).
  "${SCRIPT_DIR}/kargo-admin-up.sh"
  "${SCRIPT_DIR}/kargo-deploy-key-up.sh"
  "${SCRIPT_DIR}/kargo-image-cred-up.sh"

  "${SCRIPT_DIR}/argocd-up.sh"
  # datadog-secret-up.sh only needs kubectl (no ArgoCD sync involved), so
  # it can run as soon as the cluster exists — placed here, right after
  # ArgoCD comes up, so the datadog-secret Secret always exists before
  # datadog-agent's Application (sync-wave "1") gets anywhere near syncing.
  "${SCRIPT_DIR}/datadog-secret-up.sh"
  # Same reasoning as datadog-secret-up.sh above: registry-secret-up.sh
  # only needs kubectl, so it can run this early too — placed here so the
  # ghcr-pull imagePullSecret always exists before event-generator's
  # Application (sync-wave "1") ever tries to pull its image, instead of
  # crash-looping in ImagePullBackOff until someone runs this manually.
  "${SCRIPT_DIR}/registry-secret-up.sh"
  # Same reasoning as datadog-secret-up.sh/registry-secret-up.sh above:
  # only needs kubectl, so it can run this early too — placed here so
  # pac-forgejo-creds always exists before forgejo-repo-up.sh (which reads
  # its webhook.secret key back out) and pipelines-as-code-config's
  # Application (Task 4) ever sync.
  "${SCRIPT_DIR}/pac-forgejo-secret-up.sh"
  "${SCRIPT_DIR}/forgejo-repo-up.sh"
  # pac-forgejo-trust-up.sh (Forgejo/Pi-side: step-ca trust, DNS override,
  # ALLOWED_HOST_LIST) and pac-ca-trust-up.sh (builds the ConfigMap the
  # pipelines-as-code Deployment's SSL_CERT_FILE points at — see
  # vendor/pipelines-as-code/release.yaml) run here for the same reason as
  # the pac-forgejo-secret-up.sh/forgejo-repo-up.sh pair above: only need
  # kubectl/ssh, so running early means the PAC controller/watcher never
  # crash-loop on a missing ConfigMap or fail their outbound TLS calls to
  # Forgejo waiting on someone to run these by hand. pac-ca-trust-up.sh
  # depends on pac-forgejo-trust-up.sh having already run at least once
  # (it reads back the Forgejo container's own CA bundle).
  "${SCRIPT_DIR}/pac-forgejo-trust-up.sh"
  "${SCRIPT_DIR}/pac-ca-trust-up.sh"

  wait_for "ingress-nginx-controller has a LoadBalancer IP" 60 ingress_has_ip

  "${SCRIPT_DIR}/issuer-up.sh"
  "${SCRIPT_DIR}/dns-bootstrap.sh"
  "${SCRIPT_DIR}/pac-config-up.sh"
  "${SCRIPT_DIR}/smoke-test.sh"

  log "tekton-lab bootstrap complete"
}

main "$@"
