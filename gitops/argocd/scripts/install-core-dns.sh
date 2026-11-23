#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kthw-aws.yaml}"
# Match the Service IP used by configure-worker-dns.sh.
readonly dns_ip=10.0.0.10

helm upgrade --install coredns coredns \
  --repo https://coredns.github.io/helm \
  --version 1.50.8 \
  --namespace kube-system \
  --set-string service.name=kube-dns \
  --set-string "service.clusterIP=$dns_ip" \
  --set-string deployment.dnsPolicy=Default \
  --wait --timeout 5m

kubectl --request-timeout=10s -n kube-system get service kube-dns
kubectl --request-timeout=10s -n kube-system get endpointslices \
  -l kubernetes.io/service-name=kube-dns
