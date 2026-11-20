#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  "") recovery=false ;;
  --recovery) recovery=true ;;
  *) echo "Usage: $0 [--recovery]" >&2; exit 2 ;;
esac

tmp=$(mktemp -d)
marker="kthw-recovery-$(date +%s)-$$"
cleanup_marker=false
restore_power=false
close_web_tunnel() {
  if [[ -S "$tmp/web-ssh" ]]; then
    ssh -S "$tmp/web-ssh" -O exit "admin@$jumpbox" >/dev/null 2>&1 || true
  fi
}
cleanup() {
  close_web_tunnel
  if "$restore_power"; then
    ./lab.sh start || echo "Could not restore power after the recovery test." >&2
  fi
  if "$cleanup_marker"; then
    jump_ssh "sudo kubectl delete configmap $marker --ignore-not-found" >/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

region=$(terraform output -raw lab_region)
jumpbox=$(terraform output -raw jumpbox_instance_id)
identity=${KTHW_SSH_KEY:-"$HOME/.ssh/kthw_ed25519"}
tls_name=${KTHW_TLS_NAME:-kthw-ingress.local}
[[ -n "$region" && -n "$jumpbox" && -r "$identity" ]]
jump_ssh_options=(
  -i "$identity" -o IdentitiesOnly=yes -o BatchMode=yes
  -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
  -o "ProxyCommand=aws --profile kthw-instance-access --region $region ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
)
jump_ssh() {
  ssh "${jump_ssh_options[@]}" "admin@$jumpbox" "$@"
}

snapshot() {
  ./lab.sh status-json | python3 -c '
import json, sys
expected = sys.argv[1]
instances = json.load(sys.stdin)
assert len(instances) == 4, instances
result = {}
for i in instances:
    name = next(tag["Value"] for tag in i["Tags"] if tag["Key"] == "Name")
    assert i["State"]["Name"] == expected, (name, i["State"])
    assert bool(i.get("PublicIpAddress")) == (name == "jumpbox" and expected == "running"), name
    result[name] = [i["InstanceId"], i["PrivateIpAddress"],
                    sorted(eni["NetworkInterfaceId"] for eni in i["NetworkInterfaces"]),
                    sorted(disk["Ebs"]["VolumeId"] for disk in i["BlockDeviceMappings"])]
assert set(result) == {"jumpbox", "server", "node-0", "node-1"}, result
print(json.dumps(result, sort_keys=True))
' "$1"
}

check_routes() {
  local public private
  public=$(terraform output -raw public_route_table_id)
  private=$(terraform output -raw route_table_id)
  aws --profile kthw-provisioner --region "$region" ec2 describe-route-tables \
    --route-table-ids "$public" "$private" --output json | python3 -c '
import json, sys
public, private = sys.argv[1:3]
with open(sys.argv[3]) as f:
    hosts = json.load(f)
tables = {t["RouteTableId"]: t for t in json.load(sys.stdin)["RouteTables"]}
for table_id in (public, private):
    routes = {r.get("DestinationCidrBlock"): r for r in tables[table_id]["Routes"]}
    default = routes["0.0.0.0/0"]
    assert default["State"] == "active", default
    if table_id == public:
        assert default["GatewayId"].startswith("igw-"), default
    else:
        assert default["NetworkInterfaceId"] in hosts["jumpbox"][2], default
    for name, cidr in (("node-0", "10.200.0.0/24"), ("node-1", "10.200.1.0/24")):
        route = routes[cidr]
        assert route["State"] == "active" and route["NetworkInterfaceId"] in hosts[name][2], route
' "$public" "$private" "$tmp/before"
}

check_services() {
  local attempt
  for ((attempt=1; attempt<=12; attempt++)); do
    if jump_ssh 'sudo systemctl is-active nftables haproxy amazon-ssm-agent'; then break; fi
    if (( attempt == 12 )); then return 1; fi
    sleep 10
  done
  jump_ssh 'sudo bash -s' <<'REMOTE'
set -euo pipefail
for host in server node-0 node-1; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$host" \
    'python3 -c "from urllib.request import urlopen; urlopen(\"https://deb.debian.org/debian/README\", timeout=15).read(1)"'
done
for ((attempt=1; attempt<=12; attempt++)); do
  if kubectl --request-timeout=5s get --raw=/readyz; then break; fi
  if (( attempt == 12 )); then exit 1; fi
  sleep 10
done
kubectl wait --for=condition=Ready node/node-0 node/node-1 --timeout=180s
REMOTE

  jump_ssh 'sudo openssl x509 -in /etc/haproxy/tls/jumpbox.pem' > "$tmp/cert"
  ssh "${jump_ssh_options[@]}" -a -fNM -S "$tmp/web-ssh" \
    -o ControlPersist=no -o ExitOnForwardFailure=yes \
    -L 127.0.0.1:18080:127.0.0.1:80 -L 127.0.0.1:18443:127.0.0.1:443 "admin@$jumpbox"
  curl --noproxy '*' -fsS --retry 4 --max-time 10 \
    --connect-to "$tls_name:80:127.0.0.1:18080" "http://$tls_name/" > "$tmp/http"
  curl --noproxy '*' -fsS --retry 4 --max-time 10 --cacert "${KTHW_TLS_CA:-$tmp/cert}" \
    --connect-to "$tls_name:443:127.0.0.1:18443" "https://$tls_name/" > "$tmp/https"
  close_web_tunnel
  grep -q 'Welcome to nginx' "$tmp/http"
  grep -q 'Welcome to nginx' "$tmp/https"
  echo "SSM SSH, private SSH, web egress, Kubernetes API and tunneled HTTP/HTTPS passed."
}

check_pods() {
  jump_ssh "sudo bash -s -- $marker" <<'REMOTE'
set -euo pipefail
server="$1-server"
client="$1-client"
trap 'kubectl delete pod "$server" "$client" --ignore-not-found --wait=false' EXIT
kubectl run "$server" --image=nginx:alpine --restart=Never \
  --overrides='{"spec":{"nodeName":"node-0"}}'
kubectl run "$client" --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"nodeName":"node-1"}}' --command -- sleep 300
kubectl wait --for=condition=Ready "pod/$server" "pod/$client" --timeout=180s
ip=$(kubectl get pod "$server" -o jsonpath='{.status.podIP}')
[[ "$ip" == 10.200.0.* ]]
kubectl exec "$client" -- wget -T 10 -qO /dev/null "http://$ip/"
kubectl exec "$client" -- wget -T 10 -qO /dev/null 'http://deb.debian.org/debian/README'
REMOTE
  echo "Cross-worker pod traffic and pod web egress passed."
}

snapshot running > "$tmp/before"
check_routes
check_services
check_pods
if "$recovery"; then
  uid=$(jump_ssh "sudo kubectl create configmap $marker --from-literal=check=survives -o jsonpath='{.metadata.uid}'")
  cleanup_marker=true
  restore_power=true
  ./lab.sh stop
  snapshot stopped > "$tmp/stopped"
  cmp "$tmp/before" "$tmp/stopped"
  terraform plan -detailed-exitcode -input=false
  ./lab.sh start
  restore_power=false
  snapshot running > "$tmp/after"
  cmp "$tmp/before" "$tmp/after"
  check_routes
  check_services
  check_pods
  [[ "$uid" == "$(jump_ssh "sudo kubectl get configmap $marker -o jsonpath='{.metadata.uid}'")" ]]
  terraform plan -detailed-exitcode -input=false
  echo "Stop/start retained instance IDs, ENIs, addresses, EBS volumes and the etcd object with no Terraform plan changes."
fi
