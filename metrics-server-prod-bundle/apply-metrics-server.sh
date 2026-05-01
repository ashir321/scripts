#!/usr/bin/env bash
set -euo pipefail

INVENTORY_FILE="${1:-inventory.ini}"

./render-metrics-server-yaml.sh "$INVENTORY_FILE" metrics-server.production.template.yaml metrics-server.production.yaml
kubectl apply -f metrics-server.production.yaml
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

echo ""
echo "Verification commands:"
echo "kubectl get apiservice v1beta1.metrics.k8s.io"
echo "kubectl -n kube-system logs deploy/metrics-server --tail=80"
echo "kubectl top nodes"
echo "kubectl top pods -A"
