#!/usr/bin/env bash
# airgap-proxy-setup.sh — Apply or remove HTTP/HTTPS proxy settings on every
# node defined in inventory.ini for an air-gapped Kubernetes deployment.
#
# Proxy values are taken from inventory.ini [all:vars] but can be overridden
# on the command line.  The script configures:
#   - /etc/environment
#   - systemd drop-ins for containerd and kubelet
#
# Usage:
#   ./airgap-proxy-setup.sh [OPTIONS] [inventory.ini]
#
# Options:
#   --http-proxy  <url>   Override http_proxy / HTTP_PROXY from inventory.ini
#   --https-proxy <url>   Override https_proxy / HTTPS_PROXY from inventory.ini
#   --no-proxy    <list>  Override no_proxy / NO_PROXY from inventory.ini
#   --remove              Remove proxy settings from all nodes instead of adding
#   -h, --help            Show this help message
#
# inventory.ini variables used:
#   ssh_user      — remote login user
#   ssh_key       — path to SSH private key
#   http_proxy    — HTTP proxy URL  (e.g. http://100.112.1.142:3128)
#   https_proxy   — HTTPS proxy URL (e.g. http://100.112.1.142:3128)
#   no_proxy      — comma-separated list of addresses that bypass the proxy
#   [control_plane] and [workers] host groups
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
INVENTORY=""
OPT_HTTP_PROXY=""
OPT_HTTPS_PROXY=""
OPT_NO_PROXY=""
REMOVE=false

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --http-proxy)   OPT_HTTP_PROXY="$2";  shift 2 ;;
    --https-proxy)  OPT_HTTPS_PROXY="$2"; shift 2 ;;
    --no-proxy)     OPT_NO_PROXY="$2";    shift 2 ;;
    --remove)       REMOVE=true;          shift   ;;
    -h|--help)      usage ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      if [[ -z "${INVENTORY}" ]]; then
        INVENTORY="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

INVENTORY="${INVENTORY:-inventory.ini}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  echo
  echo "[$(date '+%F %T')] $*"
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_var() {
  local key="$1"
  local default="${2:-}"
  local val
  val="$(awk -F= -v k="$key" '
    /^\[all:vars\]/ {invars=1; next}
    /^\[/ && !/^\[all:vars\]/ {if(invars) exit}
    invars && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      sub(/^[[:space:]]+/, "", $2)
      sub(/[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$INVENTORY" 2>/dev/null || true)"
  echo "${val:-$default}"
}

get_group_hosts() {
  local group="$1"
  awk -v g="[$group]" '
    $0 == g {ingroup=1; next}
    /^\[/ {if(ingroup) exit}
    ingroup && NF && $0 !~ /^#/ {print $0}
  ' "$INVENTORY" | trim
}

# ---------------------------------------------------------------------------
# Load inventory values (CLI flags take precedence)
# ---------------------------------------------------------------------------
SSH_USER="$(get_var ssh_user)"
SSH_KEY="$(get_var ssh_key)"

HTTP_PROXY="${OPT_HTTP_PROXY:-$(get_var http_proxy)}"
HTTPS_PROXY="${OPT_HTTPS_PROXY:-$(get_var https_proxy)}"
NO_PROXY="${OPT_NO_PROXY:-$(get_var no_proxy)}"

mapfile -t CONTROL_PLANES < <(get_group_hosts control_plane)
mapfile -t WORKERS        < <(get_group_hosts workers)

NODES=("${CONTROL_PLANES[@]}" "${WORKERS[@]}")

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ ! -f "${INVENTORY}" ]]; then
  echo "Inventory file '${INVENTORY}' not found." >&2
  exit 1
fi

if [[ -z "${SSH_USER}" || -z "${SSH_KEY}" ]]; then
  echo "inventory.ini is missing ssh_user or ssh_key in [all:vars]." >&2
  exit 1
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "inventory.ini has no hosts in [control_plane] or [workers]." >&2
  exit 1
fi

if [[ "${REMOVE}" == false ]] && \
   [[ -z "${HTTP_PROXY}" && -z "${HTTPS_PROXY}" ]]; then
  echo "No proxy defined. Set http_proxy / https_proxy in inventory.ini" \
       "or pass --http-proxy / --https-proxy." >&2
  exit 1
fi

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
)

# ---------------------------------------------------------------------------
# Remote scripts
# ---------------------------------------------------------------------------
apply_proxy_script() {
  cat <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

HTTP_PROXY="${1:-}"
HTTPS_PROXY="${2:-}"
NO_PROXY="${3:-}"

# /etc/environment
cat >/etc/environment <<ENV
http_proxy=${HTTP_PROXY}
https_proxy=${HTTPS_PROXY}
no_proxy=${NO_PROXY}
HTTP_PROXY=${HTTP_PROXY}
HTTPS_PROXY=${HTTPS_PROXY}
NO_PROXY=${NO_PROXY}
ENV

# systemd drop-ins for containerd and kubelet
for service in containerd kubelet; do
  dir="/etc/systemd/system/${service}.service.d"
  mkdir -p "${dir}"
  cat >"${dir}/proxy.conf" <<DROPIN
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
DROPIN
done

systemctl daemon-reload
systemctl try-restart containerd 2>/dev/null || true
systemctl try-restart kubelet    2>/dev/null || true

echo "[INFO] Proxy settings applied on $(hostname -f 2>/dev/null || hostname)"
REMOTE
}

remove_proxy_script() {
  cat <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

# Clear /etc/environment proxy entries
if [[ -f /etc/environment ]]; then
  sed -i '/^[Hh][Tt][Tt][Pp]_[Pp][Rr][Oo][Xx][Yy]=/d
          /^[Hh][Tt][Tt][Pp][Ss]_[Pp][Rr][Oo][Xx][Yy]=/d
          /^[Nn][Oo]_[Pp][Rr][Oo][Xx][Yy]=/d' /etc/environment
fi

# Remove systemd drop-in proxy configs
for service in containerd kubelet; do
  conf="/etc/systemd/system/${service}.service.d/proxy.conf"
  if [[ -f "${conf}" ]]; then
    rm -f "${conf}"
    rmdir --ignore-fail-on-non-empty \
      "/etc/systemd/system/${service}.service.d" 2>/dev/null || true
  fi
done

systemctl daemon-reload
systemctl try-restart containerd 2>/dev/null || true
systemctl try-restart kubelet    2>/dev/null || true

echo "[INFO] Proxy settings removed from $(hostname -f 2>/dev/null || hostname)"
REMOTE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "=== airgap-proxy-setup.sh ==="
log "Inventory : ${INVENTORY}"
if [[ "${REMOVE}" == true ]]; then
  log "Mode      : REMOVE proxy settings"
else
  log "Mode      : APPLY proxy settings"
  log "HTTP_PROXY  : ${HTTP_PROXY}"
  log "HTTPS_PROXY : ${HTTPS_PROXY}"
  log "NO_PROXY    : ${NO_PROXY}"
fi
log "Nodes     : ${NODES[*]}"

for host in "${NODES[@]}"; do
  [[ -z "${host}" ]] && continue
  if [[ "${REMOVE}" == true ]]; then
    log "Removing proxy settings on ${host}"
    remove_proxy_script | \
      ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "sudo bash -s"
  else
    log "Applying proxy settings on ${host}"
    # shellcheck disable=SC2029  # proxy URLs expand client-side intentionally
    apply_proxy_script | \
      ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        "sudo bash -s -- $(printf '%q' "${HTTP_PROXY}") $(printf '%q' "${HTTPS_PROXY}") $(printf '%q' "${NO_PROXY}")"
  fi
done

log "Done. Operation completed on: ${NODES[*]}"
