#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  require_cmd kubectl
  echo "--- Nodes ---"
  kubectl get nodes
  echo "--- Cilium ---"
  kubectl -n kube-system get pods -l k8s-app=cilium
  echo "--- GatewayClass ---"
  kubectl get gatewayclass
  echo "--- ArgoCD ---"
  kubectl -n argocd get pods
  echo "--- ArgoCD Applications ---"
  kubectl -n argocd get applications
  echo "--- cert-manager ---"
  kubectl -n cert-manager get pods
  echo "--- lab-gateway ---"
  kubectl -n lab-gateway get gateway,svc
  echo "--- dnsmasq ---"
  kubectl -n dns-utils get pods,svc
  echo "--- ClusterIssuer ---"
  kubectl get clusterissuer step-ca-acme
}

main "$@"
