#!/usr/bin/env bash
set -euo pipefail

cat <<'MSG'
Run this check on every Kubernetes node.
Metrics Server 403 Forbidden usually means kubelet webhook auth/authorization is missing or broken.
Expected kubelet flags/config:
  authentication.webhook.enabled: true
  authorization.mode: Webhook

Commands:
MSG

ps -ef | grep '[k]ubelet' || true

echo ""
echo "If kubelet config file exists:"
for f in /var/lib/kubelet/config.yaml /etc/kubernetes/kubelet-config.yaml; do
  if [[ -f "$f" ]]; then
    echo "--- $f"
    grep -E 'authentication:|authorization:|webhook:|enabled:|mode:' "$f" || true
  fi
done
