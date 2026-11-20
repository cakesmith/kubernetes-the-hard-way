#!/usr/bin/env bash
set -euo pipefail

context=kubernetes-the-hard-way
api_host=server.kubernetes.local
local_port=16443
kubeconfig="$HOME/.kube/kthw-aws.yaml"

umask 077
mkdir -p "$(dirname "$kubeconfig")"
staged_config=$(mktemp "${kubeconfig}.XXXXXX")
trap 'rm -f -- "$staged_config"' EXIT

if [[ -f "$kubeconfig" ]]; then
  cat "$kubeconfig" > "$staged_config"
else
  echo "Copying the lab admin kubeconfig from jumpbox to $kubeconfig."
  if ! ssh -a -T -o ClearAllForwardings=yes jumpbox \
    'sudo -n /usr/local/bin/kubectl --kubeconfig=/root/.kube/config --context=kubernetes-the-hard-way config view --minify --flatten --raw' \
    > "$staged_config"; then
    echo "Could not export the jumpbox kubeconfig. Check SSH, sudo access, and the jumpbox kubectl setup in docs/10-configuring-kubectl.md." >&2
    exit 1
  fi
fi

cluster=$(kubectl --kubeconfig="$staged_config" --context="$context" config view \
  --minify -o jsonpath='{.clusters[0].name}')
if [[ -z "$cluster" ]]; then
  echo "Could not find the $context cluster in the lab kubeconfig." >&2
  exit 1
fi

kubectl --kubeconfig="$staged_config" config set-cluster "$cluster" \
  --server="https://127.0.0.1:$local_port" --tls-server-name="$api_host" >/dev/null
kubectl --kubeconfig="$staged_config" config use-context "$context" >/dev/null
mv -f -- "$staged_config" "$kubeconfig"
trap - EXIT

echo "Opening the Kubernetes API tunnel on 127.0.0.1:$local_port. Keep this terminal open and press Ctrl+C to close it."
printf 'In another terminal, run kubectl --kubeconfig="%s" get nodes.\n' "$kubeconfig"
exec ssh -a -NT -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:$local_port:$api_host:6443" jumpbox
