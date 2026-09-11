#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

RESOLVER_FILE="/etc/resolver/${LAB_DOMAIN}"

gateway_ip() {
  kubectl -n lab-gateway get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{end}'
}

node_ip() {
  kubectl get node "${CLUSTER_NAME}-control-plane" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

# config_checksum: see the original comment this script carried — stamped
# onto the dnsmasq Deployment's pod-template annotations so a changed
# Gateway IP forces a real rollout despite the subPath ConfigMap mount not
# being live-updated by the kubelet.
config_checksum() {
  local gw_ip="$1"
  printf 'no-resolv\naddress=/%s/%s\n' "${LAB_DOMAIN}" "${gw_ip}" | shasum -a 256 | awk '{print $1}'
}

resolver_up_to_date() {
  local node
  node=$(node_ip)
  [ -f "${RESOLVER_FILE}" ] && grep -q "nameserver ${node}" "${RESOLVER_FILE}" && grep -q "port 30053" "${RESOLVER_FILE}"
}

app_healthy() {
  local sync health
  sync=$(kubectl -n argocd get application dns -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application dns -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]
}

main() {
  require_cmd kubectl envsubst sudo shasum

  local gw_ip
  gw_ip=$(gateway_ip)
  [ -n "${gw_ip}" ] || die "lab-gateway has no LoadBalancer IP yet — run cluster-up/cilium-up/argocd-up first"

  local checksum
  checksum=$(config_checksum "${gw_ip}")

  log "applying dns Application (resolving *.${LAB_DOMAIN} -> ${gw_ip})"
  GATEWAY_IP="${gw_ip}" CONFIG_CHECKSUM="${checksum}" \
    envsubst '${GATEWAY_IP} ${CONFIG_CHECKSUM}' \
    < "${SCRIPT_DIR}/../gitops/apps-templates/dns.yaml.tmpl" | kubectl apply -f -

  wait_for "dns Application Synced and Healthy" 90 app_healthy
  kubectl -n dns-utils rollout status deployment/dnsmasq --timeout=60s

  if resolver_up_to_date; then
    log "${RESOLVER_FILE} already up to date, skipping"
    return 0
  fi

  local node
  node=$(node_ip)
  log "writing ${RESOLVER_FILE} (nameserver ${node}, port 30053) — requires sudo"
  sudo mkdir -p /etc/resolver
  printf 'nameserver %s\nport 30053\n' "${node}" | sudo tee "${RESOLVER_FILE}" >/dev/null
}

main "$@"
