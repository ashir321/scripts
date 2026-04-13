#!/usr/bin/env bash
# airgap-longhorn.sh — Install Longhorn distributed storage on an airgapped
# Kubernetes cluster using the pre-built artifact bundle from airgap-prep.sh.
#
# Usage:
#   ./airgap-longhorn.sh [inventory.ini]
#
# Required inventory.ini variables:
#   bundle_dir     — path to the bundle directory (must contain manifests/ and
#                    images/ sub-directories as created by airgap-prep.sh)
#
# Optional inventory.ini variables:
#   local_registry            — if set, manifest image refs are rewritten to
#                               point to the local registry; images are assumed
#                               to already be present in the registry.
#   LONGHORN_DATA_PATH        — data directory on each node (default: /var/lib/longhorn)
#   LONGHORN_UI_NODEPORT      — NodePort for the Longhorn UI (default: 30080)
#   LONGHORN_DEFAULT_REPLICA_COUNT — default replica count (default: 1)
set -euo pipefail

INVENTORY="${1:-inventory.ini}"

LONGHORN_VERSION="${LONGHORN_VERSION:-v1.11.1}"
LONGHORN_DATA_PATH="${LONGHORN_DATA_PATH:-/var/lib/longhorn}"
LONGHORN_UI_NODEPORT="${LONGHORN_UI_NODEPORT:-30080}"
LONGHORN_DEFAULT_REPLICA_COUNT="${LONGHORN_DEFAULT_REPLICA_COUNT:-1}"

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
  ' "$INVENTORY")"
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
# Inventory values
# ---------------------------------------------------------------------------
SSH_USER="$(get_var ssh_user)"
SSH_KEY="$(get_var ssh_key)"
BUNDLE_DIR="$(get_var bundle_dir './bundle')"
LOCAL_REGISTRY="$(get_var local_registry '')"

# Override defaults from inventory if present
LONGHORN_VERSION="$(get_var LONGHORN_VERSION "${LONGHORN_VERSION}")"
LONGHORN_DATA_PATH="$(get_var LONGHORN_DATA_PATH "${LONGHORN_DATA_PATH}")"
LONGHORN_UI_NODEPORT="$(get_var LONGHORN_UI_NODEPORT "${LONGHORN_UI_NODEPORT}")"
LONGHORN_DEFAULT_REPLICA_COUNT="$(get_var LONGHORN_DEFAULT_REPLICA_COUNT "${LONGHORN_DEFAULT_REPLICA_COUNT}")"

mapfile -t CONTROL_PLANES < <(get_group_hosts control_plane)
mapfile -t WORKERS        < <(get_group_hosts workers)

CONTROL_PLANE_IP="${CONTROL_PLANES[0]:-}"

if [[ -z "${SSH_USER}" || -z "${SSH_KEY}" || -z "${CONTROL_PLANE_IP}" ]]; then
  echo "inventory.ini is missing required values: ssh_user, ssh_key, or control_plane"
  exit 1
fi

if [[ ! -d "${BUNDLE_DIR}" ]]; then
  echo "Bundle directory '${BUNDLE_DIR}' not found."
  echo "Run airgap-prep.sh first, then set bundle_dir in inventory.ini."
  exit 1
fi

REMOTE_BUNDLE="/tmp/k8s-airgap-bundle"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=120
)

remote() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

remote_sudo() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "sudo bash -lc $(printf '%q' "$*")"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
check_access() {
  local nodes=("${CONTROL_PLANE_IP}" "${WORKERS[@]}")
  for n in "${nodes[@]}"; do
    [[ -n "${n}" ]] || continue
    log "Checking SSH + passwordless sudo on ${n}"
    remote "${n}" "id >/dev/null"
    remote "${n}" "sudo -n true"
  done
}

# ---------------------------------------------------------------------------
# Node prerequisites (iSCSI, NFS, etc.) — same as install_longhorn_kubectl.sh
# ---------------------------------------------------------------------------
node_prereq_script() {
  cat <<'NODE_PREREQ'
#!/usr/bin/env bash
set -euo pipefail

LONGHORN_DATA_PATH="${1:-/var/lib/longhorn}"

echo "[INFO] Installing Longhorn node prerequisites (airgapped)"

OS_ID=""; OS_LIKE=""
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-}"; OS_LIKE="${ID_LIKE:-}"
fi

install_pkgs_rpm() {
  local pm="yum"; command -v dnf >/dev/null 2>&1 && pm="dnf"
  ${pm} makecache -y || true
  ${pm} install -y \
    iscsi-initiator-utils nfs-utils cryptsetup \
    device-mapper-persistent-data util-linux \
    curl jq tar gzip findutils gawk grep coreutils
}

install_pkgs_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    open-iscsi nfs-common cryptsetup util-linux \
    curl jq tar gzip findutils gawk grep coreutils
}

case "${OS_ID}:${OS_LIKE}" in
  ubuntu:*|debian:*|*:debian*)
    install_pkgs_deb; ISCSI_SERVICE="iscsid" ;;
  rhel:*|centos:*|rocky:*|almalinux:*|ol:*|amzn:*|*:rhel*|*:fedora*)
    install_pkgs_rpm; ISCSI_SERVICE="iscsid"
    mkdir -p /etc/iscsi
    if [[ ! -s /etc/iscsi/initiatorname.iscsi ]] && \
       command -v iscsi-iname >/dev/null 2>&1; then
      echo "InitiatorName=$(iscsi-iname)" >/etc/iscsi/initiatorname.iscsi
    fi
    ;;
  *)
    echo "[ERROR] Unsupported OS: ${OS_ID} ${OS_LIKE}"; exit 1 ;;
esac

mkdir -p /etc/modules-load.d
cat >/etc/modules-load.d/longhorn.conf <<'EOF'
iscsi_tcp
dm_crypt
EOF

modprobe iscsi_tcp || true
modprobe dm_crypt  || true

systemctl enable --now "${ISCSI_SERVICE}" || true
systemctl restart "${ISCSI_SERVICE}" || true

if systemctl list-unit-files | awk '{print $1}' | grep -qx iscsi.service; then
  systemctl enable --now iscsi || true
fi

mkdir -p "${LONGHORN_DATA_PATH}"
chmod 755 "${LONGHORN_DATA_PATH}"

command -v iscsiadm >/dev/null 2>&1 || { echo "[ERROR] iscsiadm not found"; exit 1; }
systemctl is-active --quiet "${ISCSI_SERVICE}" || \
  { echo "[ERROR] ${ISCSI_SERVICE} is not active"; exit 1; }

echo "[INFO] Longhorn prereqs ready on $(hostname -f 2>/dev/null || hostname)"
NODE_PREREQ
}

prepare_node() {
  local host="$1"
  log "Installing Longhorn prerequisites on ${host}"
  node_prereq_script | \
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
      "sudo bash -s -- '${LONGHORN_DATA_PATH}'"
}

prepare_all_nodes() {
  prepare_node "${CONTROL_PLANE_IP}"
  for w in "${WORKERS[@]}"; do
    [[ -n "${w}" ]] || continue
    prepare_node "${w}"
  done
}

# ---------------------------------------------------------------------------
# Load Longhorn images on every node (no-registry path)
# ---------------------------------------------------------------------------
load_longhorn_images_on_node() {
  local host="$1"
  log "Loading Longhorn images on ${host}"

  # Upload images directory if not already there from airgap-bootstrap.sh
  remote_sudo "${host}" "mkdir -p '${REMOTE_BUNDLE}/images'"
  scp "${SSH_OPTS[@]}" -r \
    "${BUNDLE_DIR}/images" \
    "${host}:${REMOTE_BUNDLE}/"

  remote_sudo "${host}" "
    shopt -s nullglob
    for img in '${REMOTE_BUNDLE}/images/'*.tar; do
      name=\$(basename \"\${img}\")
      # Only (re-)import Longhorn images; skip if already present
      if echo \"\${name}\" | grep -qi 'longhorn'; then
        echo \"  Loading \${name}\"
        ctr -n k8s.io images import \"\${img}\"
      fi
    done
  "
}

load_longhorn_images_all_nodes() {
  if [[ -n "${LOCAL_REGISTRY}" ]]; then
    log "Local registry in use — skipping image tarball upload"
    return
  fi
  load_longhorn_images_on_node "${CONTROL_PLANE_IP}"
  for w in "${WORKERS[@]}"; do
    [[ -n "${w}" ]] || continue
    load_longhorn_images_on_node "${w}"
  done
}

# ---------------------------------------------------------------------------
# Upload manifests and apply
# ---------------------------------------------------------------------------
install_longhorn_manifest() {
  log "Installing Longhorn ${LONGHORN_VERSION}"

  # Upload manifests directory
  remote_sudo "${CONTROL_PLANE_IP}" \
    "mkdir -p '${REMOTE_BUNDLE}/manifests'"
  scp "${SSH_OPTS[@]}" -r \
    "${BUNDLE_DIR}/manifests" \
    "${CONTROL_PLANE_IP}:${REMOTE_BUNDLE}/"

  log "Patching Longhorn manifest (data path, replicas, registry)"
  remote "${CONTROL_PLANE_IP}" "
    cp '${REMOTE_BUNDLE}/manifests/longhorn.yaml' /tmp/longhorn-airgap.yaml

    python3 - <<'PY'
from pathlib import Path

p = Path('/tmp/longhorn-airgap.yaml')
text = p.read_text()

text = text.replace(
    'default-data-path: /var/lib/longhorn',
    'default-data-path: ${LONGHORN_DATA_PATH}'
)
text = text.replace(
    'numberOfReplicas: \"3\"',
    'numberOfReplicas: \"${LONGHORN_DEFAULT_REPLICA_COUNT}\"'
)

# Rewrite image references when a local registry is configured
local_reg = '${LOCAL_REGISTRY}'
if local_reg:
    import re
    def rewrite_image(m):
        img = m.group(1)
        # Strip known public registries
        img = re.sub(r'^(docker\.io/|longhornio/)', '', img)
        return f'image: {local_reg}/longhornio/{img}'
    text = re.sub(r'image:\s+(?:docker\.io/)?longhornio/(\S+)', rewrite_image, text)

p.write_text(text)
print('[INFO] Manifest patched')
PY
  "

  remote "${CONTROL_PLANE_IP}" "
    kubectl get ns longhorn-system >/dev/null 2>&1 || \
      kubectl create ns longhorn-system
    kubectl apply -f /tmp/longhorn-airgap.yaml
  "
}

# ---------------------------------------------------------------------------
# Post-install configuration
# ---------------------------------------------------------------------------
expose_longhorn_ui_nodeport() {
  log "Exposing Longhorn UI via NodePort ${LONGHORN_UI_NODEPORT}"
  remote "${CONTROL_PLANE_IP}" "
    kubectl -n longhorn-system patch svc longhorn-frontend \
      --type merge -p '
{
  \"spec\": {
    \"type\": \"NodePort\",
    \"ports\": [{
      \"name\": \"http\",
      \"port\": 80,
      \"protocol\": \"TCP\",
      \"targetPort\": 8000,
      \"nodePort\": ${LONGHORN_UI_NODEPORT}
    }]
  }
}'
  "
}

set_default_storageclass() {
  log "Making Longhorn the default StorageClass"
  remote "${CONTROL_PLANE_IP}" "
    kubectl patch storageclass longhorn \
      -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}' \
    || true
  "
}

wait_for_longhorn() {
  log "Waiting for Longhorn components to become ready (up to 15 min)"
  remote "${CONTROL_PLANE_IP}" "
    kubectl -n longhorn-system rollout status \
      deploy/longhorn-driver-deployer --timeout=15m || true
    kubectl -n longhorn-system rollout status \
      deploy/longhorn-ui             --timeout=15m || true
    kubectl -n longhorn-system get pods -o wide
  "
}

show_status() {
  log "Longhorn status"
  remote "${CONTROL_PLANE_IP}" "
    echo '=== Pods ==='
    kubectl -n longhorn-system get pods -o wide
    echo
    echo '=== Services ==='
    kubectl -n longhorn-system get svc
    echo
    echo '=== StorageClasses ==='
    kubectl get sc
  "
}

print_next_steps() {
  cat <<EOF

Done.

Longhorn version : ${LONGHORN_VERSION}
Control plane    : ${CONTROL_PLANE_IP}
Workers          : ${WORKERS[*]:-<none>}
Data path        : ${LONGHORN_DATA_PATH}
Default replicas : ${LONGHORN_DEFAULT_REPLICA_COUNT}
UI NodePort      : ${LONGHORN_UI_NODEPORT}

Open UI:
  http://${CONTROL_PLANE_IP}:${LONGHORN_UI_NODEPORT}
EOF
  for w in "${WORKERS[@]}"; do
    [[ -n "${w}" ]] || continue
    echo "  http://${w}:${LONGHORN_UI_NODEPORT}"
  done
  cat <<'EOF'

Verify:
  kubectl -n longhorn-system get pods -o wide
  kubectl -n longhorn-system get svc longhorn-frontend
  kubectl get sc longhorn -o yaml | grep -A3 numberOfReplicas
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== airgap-longhorn.sh ==="
  log "Inventory      : ${INVENTORY}"
  log "Bundle dir     : ${BUNDLE_DIR}"
  log "Longhorn       : ${LONGHORN_VERSION}"
  log "Control plane  : ${CONTROL_PLANE_IP}"
  log "Workers        : ${WORKERS[*]:-<none>}"
  log "Local registry : ${LOCAL_REGISTRY:-<none — loading from tarballs>}"

  check_access
  prepare_all_nodes
  load_longhorn_images_all_nodes
  install_longhorn_manifest
  expose_longhorn_ui_nodeport
  set_default_storageclass
  wait_for_longhorn
  show_status
  print_next_steps
}

main "$@"
