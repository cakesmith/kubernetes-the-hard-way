#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kthw-aws.yaml}"
readonly dns_ip=10.0.0.10
readonly dns_domain=cluster.local
readonly -a workers=(node-0 node-1)

service_ip=$(kubectl --request-timeout=10s -n kube-system get service kube-dns \
  -o 'jsonpath={.spec.clusterIP}')
ready_endpoints=$(kubectl --request-timeout=10s -n kube-system get endpointslices \
  -l kubernetes.io/service-name=kube-dns \
  -o 'jsonpath={.items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}')
if [[ $service_ip != "$dns_ip" || -z $ready_endpoints ]]; then
  echo "Install CoreDNS and verify kube-system/kube-dns has IP $dns_ip and a ready endpoint." >&2
  exit 1
fi

for worker in "${workers[@]}"; do
  printf 'Configuring %s\n' "$worker"
  ssh -o BatchMode=yes "$worker" sudo -n bash -s -- "$dns_ip" "$dns_domain" <<'REMOTE'
set -euo pipefail

dns_ip=$1
dns_domain=$2
config=/var/lib/kubelet/kubelet-config.yaml
exec 9>"$config.dns.lock"
flock -n 9

staged=$(mktemp "$config.dns.XXXXXX")
trap 'rm -f -- "$staged"' EXIT
cp --preserve=mode,ownership -- "$config" "$staged"

# Replace the lab config's top-level DNS keys and their block-list items.
awk -v ip="$dns_ip" -v domain="$dns_domain" '
  /^clusterDNS[[:space:]]*:/ { in_dns_list = 1; next }
  in_dns_list && /^[[:space:]]*-[[:space:]]/ { next }
  !/^[[:space:]]*(#|$)/ { in_dns_list = 0 }
  /^clusterDomain[[:space:]]*:/ { next }
  { print }
  END {
    print "clusterDNS:"
    print "  - " ip
    print "clusterDomain: " domain
  }
' "$config" > "$staged"

if cmp -s "$config" "$staged"; then
  echo "Kubelet DNS is already configured."
else
  backup=$(mktemp "$config.before-coredns.XXXXXX")
  cp -a -- "$config" "$backup"
  printf 'Backup saved to %s\n' "$backup"
  mv -f -- "$staged" "$config"
  if ! systemctl restart kubelet; then
    cp -a -- "$backup" "$config"
    systemctl restart kubelet
    echo "Kubelet restart failed. Restored $backup." >&2
    exit 1
  fi
fi
REMOTE

  # A stale Node Ready condition alone cannot confirm the restarted kubelet.
  active=false
  for attempt in {1..12}; do
    if active_config=$(kubectl --request-timeout=5s get --raw="/api/v1/nodes/$worker/proxy/configz") &&
      python3 -c '
import json
import sys

config = json.load(sys.stdin)["kubeletconfig"]
sys.exit(config.get("clusterDNS") != [sys.argv[1]] or config.get("clusterDomain") != sys.argv[2])
' "$dns_ip" "$dns_domain" <<< "$active_config"; then
      active=true
      break
    fi
    sleep 2
  done
  if [[ $active != true ]]; then
    echo "Could not verify the active DNS settings on $worker. Check kubelet status and the backup path above." >&2
    exit 1
  fi
  kubectl --request-timeout=10s wait --for=condition=Ready "node/$worker" --timeout=60s
done
