#!/usr/bin/env bash
set -euo pipefail

INVENTORY="${1:-inventory.ini}"

log() {
  echo
  echo "[$(date '+%F %T')] $*"
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_var() {
  local key="$1"
  awk -F= -v k="$key" '
    /^\[all:vars\]/ {invars=1; next}
    /^\[/ && !/^\[all:vars\]/ {if(invars) exit}
    invars && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$INVENTORY"
}

get_group_hosts() {
  local group="$1"
  awk -v g="[$group]" '
    $0 == g {ingroup=1; next}
    /^\[/ {if(ingroup) exit}
    ingroup && NF && $0 !~ /^#/ {print $0}
  ' "$INVENTORY" | trim
}

SSH_USER="$(get_var ssh_user)"
SSH_KEY="$(get_var ssh_key)"
HTTP_PROXY="$(get_var http_proxy)"
HTTPS_PROXY="$(get_var https_proxy)"
NO_PROXY="$(get_var no_proxy)"

mapfile -t CONTROL_PLANES < <(get_group_hosts control_plane)
mapfile -t WORKERS < <(get_group_hosts workers)

NODES=("${CONTROL_PLANES[@]}" "${WORKERS[@]}")

if [[ -z "${SSH_USER}" || -z "${SSH_KEY}" ]]; then
  echo "inventory.ini is missing ssh_user or ssh_key in [all:vars]."
  exit 1
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "inventory.ini has no hosts in [control_plane] or [workers]."
  exit 1
fi

if [[ -z "${HTTP_PROXY}" && -z "${HTTPS_PROXY}" ]]; then
  echo "inventory.ini must define at least one of http_proxy or https_proxy."
  exit 1
fi

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

apply_proxy_script() {
  cat <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

HTTP_PROXY="${1:-}"
HTTPS_PROXY="${2:-}"
NO_PROXY="${3:-}"

cat >/etc/environment <<ENV_FILE
http_proxy=${HTTP_PROXY}
https_proxy=${HTTPS_PROXY}
no_proxy=${NO_PROXY}
HTTP_PROXY=${HTTP_PROXY}
HTTPS_PROXY=${HTTPS_PROXY}
NO_PROXY=${NO_PROXY}
ENV_FILE

for service in containerd kubelet; do
  mkdir -p "/etc/systemd/system/${service}.service.d"
  cat >"/etc/systemd/system/${service}.service.d/proxy.conf" <<SERVICE_PROXY
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
SERVICE_PROXY
done

systemctl daemon-reload
systemctl restart containerd || true
systemctl restart kubelet || true

echo "[INFO] Proxy configuration updated"
REMOTE
}

for host in "${NODES[@]}"; do
  [[ -z "${host}" ]] && continue
  log "Applying proxy settings on ${host}"
  apply_proxy_script | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
    "sudo bash -s -- '${HTTP_PROXY}' '${HTTPS_PROXY}' '${NO_PROXY}'"
done

log "Done. Proxy settings applied to: ${NODES[*]}"

