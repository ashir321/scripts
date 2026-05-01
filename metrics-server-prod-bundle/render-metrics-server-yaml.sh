#!/usr/bin/env bash
set -euo pipefail

INVENTORY_FILE="${1:-inventory.ini}"
TEMPLATE_FILE="${2:-metrics-server.production.template.yaml}"
OUTPUT_FILE="${3:-metrics-server.production.yaml}"

if [[ ! -f "$INVENTORY_FILE" ]]; then
  echo "ERROR: inventory file not found: $INVENTORY_FILE" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "ERROR: template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

get_var() {
  local key="$1"
  local value
  value="$(awk -F= -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[[:space:]]*/, "", $2); sub(/[[:space:]]*$/, "", $2); print $2
    }' "$INVENTORY_FILE" | tail -n1)"
  printf '%s' "$value"
}

normalize_proxy() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf ''
  elif [[ "$value" =~ ^https?:// ]]; then
    printf '%s' "$value"
  else
    printf 'http://%s' "$value"
  fi
}

HTTP_PROXY_VALUE="$(normalize_proxy "$(get_var HTTP_PROXY)")"
HTTPS_PROXY_VALUE="$(normalize_proxy "$(get_var HTTPS_PROXY)")"
http_proxy_VALUE="$(normalize_proxy "$(get_var http_proxy)")"
https_proxy_VALUE="$(normalize_proxy "$(get_var https_proxy)")"
NO_PROXY_VALUE="$(get_var NO_PROXY)"
no_proxy_VALUE="$(get_var no_proxy)"
LOCAL_REGISTRY="$(get_var local_registry)"

# Fix accidental typo if present in inventory.
NO_PROXY_VALUE="${NO_PROXY_VALUE//.svc.cluster.local8/.svc.cluster.local}"
no_proxy_VALUE="${no_proxy_VALUE//.svc.cluster.local8/.svc.cluster.local}"

# Ensure all node and service CIDRs used by your cluster are bypassed.
append_no_proxy() {
  local current="$1"
  shift
  local item
  for item in "$@"; do
    if [[ ",$current," != *",$item,"* ]]; then
      current="${current:+$current,}$item"
    fi
  done
  printf '%s' "$current"
}

NO_PROXY_VALUE="$(append_no_proxy "$NO_PROXY_VALUE" \
  localhost 127.0.0.1 \
  1.10.0.0/16 11.10.0.0/16 \
  10.96.0.0/12 10.244.0.0/16 192.168.0.0/16 \
  .svc .svc.cluster.local kubernetes.default.svc)"

no_proxy_VALUE="$(append_no_proxy "$no_proxy_VALUE" \
  localhost 127.0.0.1 \
  1.10.0.0/16 11.10.0.0/16 \
  10.96.0.0/12 10.244.0.0/16 192.168.0.0/16 \
  .svc .svc.cluster.local kubernetes.default.svc)"

if [[ -n "$LOCAL_REGISTRY" ]]; then
  METRICS_SERVER_IMAGE="${LOCAL_REGISTRY}/metrics-server/metrics-server:v0.8.0"
else
  METRICS_SERVER_IMAGE="registry.k8s.io/metrics-server/metrics-server:v0.8.0"
fi

sed \
  -e "s|__METRICS_SERVER_IMAGE__|${METRICS_SERVER_IMAGE}|g" \
  -e "s|__HTTP_PROXY__|${HTTP_PROXY_VALUE}|g" \
  -e "s|__HTTPS_PROXY__|${HTTPS_PROXY_VALUE}|g" \
  -e "s|__NO_PROXY__|${NO_PROXY_VALUE}|g" \
  -e "s|__http_proxy__|${http_proxy_VALUE}|g" \
  -e "s|__https_proxy__|${https_proxy_VALUE}|g" \
  -e "s|__no_proxy__|${no_proxy_VALUE}|g" \
  "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Rendered: $OUTPUT_FILE"
echo "Image: $METRICS_SERVER_IMAGE"
echo "HTTP_PROXY: $HTTP_PROXY_VALUE"
echo "HTTPS_PROXY: $HTTPS_PROXY_VALUE"
echo "NO_PROXY: $NO_PROXY_VALUE"
