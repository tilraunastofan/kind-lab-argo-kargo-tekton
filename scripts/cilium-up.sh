#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

GATEWAY_API_VERSION="v1.1.0"
CILIUM_VERSION="1.16.5"

install_gateway_api_crds() {
  # Cilium 1.16.x's Gateway API controller requires the TLSRoute CRD to start
  # reconciling at all, and only understands the pre-v1.2 "supportedFeatures"
  # schema (a list of strings; v1.2 changed it to a list of objects). The
  # "experimental" channel manifest ships TLSRoute; pinning to v1.1.0 keeps
  # the CRD schema compatible with Cilium 1.16.5.
  log "applying Gateway API CRDs (${GATEWAY_API_VERSION}, experimental channel)"
  if ! kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"; then
    warn "kubectl apply of the Gateway API CRDs failed. This can happen on a genuinely fresh cluster:"
    warn "cloud-provider-kind's own embedded Gateway API controller-runtime manager can race this apply and record a"
    warn "'v1' storedVersion on the alpha-only backendtlspolicies/tlsroutes CRDs, which Gateway API v1.1.0 doesn't"
    warn "define a v1 version for — the apiserver then refuses this apply as a CRD safety check."
    echo
    echo "  kubectl patch crd backendtlspolicies.gateway.networking.k8s.io --subresource=status --type=merge -p '{\"status\":{\"storedVersions\":[\"v1alpha3\"]}}'"
    echo "  kubectl patch crd tlsroutes.gateway.networking.k8s.io --subresource=status --type=merge -p '{\"status\":{\"storedVersions\":[\"v1alpha2\"]}}'"
    echo
    die "run the commands above, then re-run bootstrap.sh"
  fi
}

install_cilium() {
  log "installing Cilium ${CILIUM_VERSION} (CNI + Gateway API)"
  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values "${SCRIPT_DIR}/../helm/cilium/values.yaml" \
    --kube-context "kind-${CLUSTER_NAME}" \
    --wait --timeout 5m
}

nodes_ready() {
  local not_ready
  not_ready=$(kubectl get nodes --no-headers | grep -vc " Ready ")
  [ "${not_ready}" -eq 0 ]
}

gatewayclass_accepted() {
  local status
  status=$(kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [ "${status}" = "True" ]
}

main() {
  require_cmd kubectl helm
  install_gateway_api_crds
  install_cilium
  wait_for "all nodes Ready" 180 nodes_ready
  wait_for "GatewayClass 'cilium' accepted" 120 gatewayclass_accepted
  log "Cilium installed and cluster is Ready"
}

main "$@"
