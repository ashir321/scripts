#!/usr/bin/env bash
# airgap-bootstrap.sh — Bootstrap a Kubernetes cluster from a pre-built
# artifact bundle, with no internet access required on the target nodes.
#
# Usage:
#   ./airgap-bootstrap.sh [inventory.ini]
#
# Required inventory.ini variables (in addition to the standard ones):
#   bundle_dir        — local path to the bundle created by airgap-prep.sh
#
# Optional inventory.ini variables:
#   local_registry    — if set (e.g. registry.local:5000), images are pulled
#                       from this registry instead of being loaded from tarballs.
#                       The registry must already be populated (e.g. with
#                       airgap-push.sh or a mirror tool such as Skopeo).
#   pause_image       — override the containerd sandbox image
#                       (default: auto-detected from the loaded K8s images)
#
# Workflow when local_registry is EMPTY (default):
#   - RPMs are uploaded and installed on every node
#   - Container image tarballs are uploaded and imported into containerd
#   - kubeadm init uses the default registry.k8s.io prefix (images already
#     present in containerd, so no pull is attempted)
#
# Workflow when local_registry is SET:
#   - RPMs are uploaded and installed on every node
#   - containerd is configured with a registry mirror for registry.k8s.io
#     and docker.io pointing to local_registry
#   - kubeadm init uses --image-repository=<local_registry>
#   - Calico / Longhorn manifests are patched to reference local_registry
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
K8S_MINOR_VERSION="$(get_var k8s_minor_version)"
POD_CIDR="$(get_var pod_cidr)"
CALICO_URL="$(get_var calico_url)"
BUNDLE_DIR="$(get_var bundle_dir './bundle')"
LOCAL_REGISTRY="$(get_var local_registry '')"
PAUSE_IMAGE="$(get_var pause_image '')"

mapfile -t CONTROL_PLANES < <(get_group_hosts control_plane)
mapfile -t WORKERS        < <(get_group_hosts workers)

CONTROL_PLANE_IP="${CONTROL_PLANES[0]:-}"

if [[ -z "${SSH_USER}" || -z "${SSH_KEY}" || -z "${CONTROL_PLANE_IP}" ]]; then
  echo "inventory.ini is missing required values (ssh_user, ssh_key, control_plane)."
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
# Preflight checks
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
# Bundle upload
# ---------------------------------------------------------------------------
upload_bundle() {
  local host="$1"
  log "Uploading bundle to ${host}:${REMOTE_BUNDLE}"
  # Clean up any root-owned remnant from a previous run, then create the
  # directory as SSH_USER so that subsequent scp writes succeed.
  remote_sudo "${host}" "rm -rf '${REMOTE_BUNDLE}'"
  remote      "${host}" "mkdir -p '${REMOTE_BUNDLE}'"
  scp "${SSH_OPTS[@]}" -r \
    "${BUNDLE_DIR}/rpms" \
    "${host}:${REMOTE_BUNDLE}/"
  # Only upload images if not using a local registry
  if [[ -z "${LOCAL_REGISTRY}" ]]; then
    scp "${SSH_OPTS[@]}" -r \
      "${BUNDLE_DIR}/images" \
      "${host}:${REMOTE_BUNDLE}/"
  fi
}

# ---------------------------------------------------------------------------
# Per-node preparation script (runs as root on remote)
# ---------------------------------------------------------------------------
node_prep_script() {
  cat <<NODE_PREP
#!/usr/bin/env bash
set -euo pipefail

BUNDLE_PATH="\${1}"
NODE_ROLE="\${2}"
K8S_MINOR_VERSION="\${3}"
LOCAL_REGISTRY="\${4:-}"
PAUSE_IMAGE="\${5:-}"

echo "[INFO] Airgapped node prep — role: \${NODE_ROLE}"

# ---- System preparation (same as online bootstrap) ----
swapoff -a || true
if grep -Eq '^[^#].*\sswap\s' /etc/fstab; then
  cp -a /etc/fstab /etc/fstab.bak.\$(date +%F-%H%M%S)
  sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab
fi

if command -v setenforce >/dev/null 2>&1; then setenforce 0 || true; fi
if [[ -f /etc/selinux/config ]]; then
  sed -ri 's/^SELINUX=enforcing\$/SELINUX=permissive/' /etc/selinux/config
fi

cat >/etc/modules-load.d/k8s.conf <<'MODS'
overlay
br_netfilter
MODS

modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL

sysctl --system >/dev/null

# ---- Package installation from bundle RPMs ----
echo "[INFO] Installing utility RPMs"
dnf install -y --nogpgcheck "\${BUNDLE_PATH}/rpms/utils/"*.rpm 2>/dev/null || true

echo "[INFO] Installing containerd from bundle"
dnf install -y --nogpgcheck "\${BUNDLE_PATH}/rpms/containerd/"*.rpm

echo "[INFO] Installing Kubernetes components from bundle"
dnf install -y --nogpgcheck "\${BUNDLE_PATH}/rpms/k8s/"*.rpm

# ---- Configure containerd ----
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# If a local registry is specified, configure containerd mirrors so that
# pulls from registry.k8s.io and docker.io are served by the local registry.
if [[ -n "\${LOCAL_REGISTRY}" ]]; then
  echo "[INFO] Configuring containerd registry mirrors → \${LOCAL_REGISTRY}"
  # Update sandbox (pause) image to use local registry
  PAUSE_TAG=\$(grep 'sandbox_image' /etc/containerd/config.toml \
    | grep -oP '(?<=")[^"]+(?=")' | tail -1)
  PAUSE_NAME=\$(basename "\${PAUSE_TAG%%:*}")
  PAUSE_VER=\${PAUSE_TAG##*:}
  sed -ri "s|sandbox_image = .*|sandbox_image = \"\${LOCAL_REGISTRY}/\${PAUSE_NAME}:\${PAUSE_VER}\"|" \
    /etc/containerd/config.toml

  # Inject mirror config into config.toml
  python3 - <<'PY'
import re, sys
from pathlib import Path

cfg = Path('/etc/containerd/config.toml')
text = cfg.read_text()

import os
reg = os.environ.get('LOCAL_REGISTRY', '')

mirror_block = f'''
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
          endpoint = ["http://{reg}"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = ["http://{reg}"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
          endpoint = ["http://{reg}"]
'''

# Insert before the end of the [plugins."io.containerd.grpc.v1.cri"] section
if 'registry.mirrors' not in text:
    text = text + mirror_block
    cfg.write_text(text)
    print('[INFO] Registry mirrors injected into config.toml')
else:
    print('[INFO] Registry mirrors already present in config.toml')
PY
fi

# Override pause/sandbox image if explicitly requested
if [[ -n "\${PAUSE_IMAGE}" ]]; then
  sed -ri "s|sandbox_image = .*|sandbox_image = \"\${PAUSE_IMAGE}\"|" \
    /etc/containerd/config.toml
fi

systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

cat >/etc/crictl.yaml <<'CRICTL'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint:   unix:///run/containerd/containerd.sock
timeout: 10
debug:   false
pull-image-on-create: false
CRICTL

# ---- Load container images ----
if [[ -z "\${LOCAL_REGISTRY}" ]]; then
  IMAGE_DIR="\${BUNDLE_PATH}/images"
  if [[ -d "\${IMAGE_DIR}" ]]; then
    echo "[INFO] Loading container images into containerd (k8s.io namespace)"
    shopt -s nullglob
    for img in "\${IMAGE_DIR}"/*.tar; do
      echo "  \$(basename "\${img}")"
      ctr -n k8s.io images import "\${img}"
    done
  else
    echo "[WARN] No images/ directory found in bundle — assuming local_registry is used."
  fi
fi

# ---- Enable kubelet ----
systemctl enable --now kubelet

# ---- Firewall ----
if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-port=6443/tcp   || true
  firewall-cmd --permanent --add-port=2379-2380/tcp || true
  firewall-cmd --permanent --add-port=10250/tcp  || true
  firewall-cmd --permanent --add-port=10257/tcp  || true
  firewall-cmd --permanent --add-port=10259/tcp  || true
  firewall-cmd --reload || true
fi

echo "[INFO] Node prep complete on \$(hostname -f 2>/dev/null || hostname)"
NODE_PREP
}

prepare_node() {
  local host="$1"
  local role="$2"
  log "Preparing ${role} node ${host}"
  node_prep_script | \
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
      "sudo bash -s -- \
         '${REMOTE_BUNDLE}' \
         '${role}' \
         '${K8S_MINOR_VERSION}' \
         '${LOCAL_REGISTRY}' \
         '${PAUSE_IMAGE}'"
}

prepare_all_nodes() {
  upload_bundle "${CONTROL_PLANE_IP}"
  prepare_node  "${CONTROL_PLANE_IP}" control-plane

  for w in "${WORKERS[@]}"; do
    [[ -n "${w}" ]] || continue
    upload_bundle "${w}"
    prepare_node  "${w}" worker
  done
}

# ---------------------------------------------------------------------------
# Control-plane init
# ---------------------------------------------------------------------------
init_control_plane() {
  log "Initialising control plane on ${CONTROL_PLANE_IP}"

  local img_repo_flag=""
  if [[ -n "${LOCAL_REGISTRY}" ]]; then
    img_repo_flag="--image-repository='${LOCAL_REGISTRY}'"
    log "Using local registry: ${LOCAL_REGISTRY}"
  else
    log "Using pre-loaded images (no local registry)"
    # Pre-pull is handled by the images already being in containerd;
    # skip the online image pull step that bootstrap.sh would run.
  fi

  remote_sudo "${CONTROL_PLANE_IP}" "
    if [[ ! -f /etc/kubernetes/admin.conf ]]; then
      kubeadm init \
        --apiserver-advertise-address='${CONTROL_PLANE_IP}' \
        --pod-network-cidr='${POD_CIDR}' \
        ${img_repo_flag}
    fi
  "
}

configure_kubectl() {
  log "Configuring kubectl on control plane for ${SSH_USER}"
  remote "${CONTROL_PLANE_IP}" "
    mkdir -p \$HOME/.kube &&
    sudo cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config &&
    sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config &&
    chmod 600 \$HOME/.kube/config
  "
}

# ---------------------------------------------------------------------------
# CNI (Calico) — from local manifest
# ---------------------------------------------------------------------------
install_cni() {
  log "Installing Calico CNI from local bundle manifest"

  # Upload manifests to control plane
  scp "${SSH_OPTS[@]}" -r \
    "${BUNDLE_DIR}/manifests" \
    "${CONTROL_PLANE_IP}:${REMOTE_BUNDLE}/"

  if [[ -n "${LOCAL_REGISTRY}" ]]; then
    log "Patching Calico manifest to reference ${LOCAL_REGISTRY}"
    remote "${CONTROL_PLANE_IP}" "
      cp '${REMOTE_BUNDLE}/manifests/calico.yaml' /tmp/calico-airgap.yaml
      sed -i 's|docker.io/calico/|${LOCAL_REGISTRY}/calico/|g' /tmp/calico-airgap.yaml
      kubectl apply -f /tmp/calico-airgap.yaml
    "
  else
    remote "${CONTROL_PLANE_IP}" \
      "kubectl apply -f '${REMOTE_BUNDLE}/manifests/calico.yaml'"
  fi
}

# ---------------------------------------------------------------------------
# Worker join
# ---------------------------------------------------------------------------
join_workers() {
  if [[ ${#WORKERS[@]} -eq 0 ]]; then
    log "No worker nodes defined — skipping join step"
    return
  fi

  log "Generating worker join command"
  local join_cmd
  join_cmd="$(remote_sudo "${CONTROL_PLANE_IP}" \
    "kubeadm token create --print-join-command")"

  for w in "${WORKERS[@]}"; do
    [[ -n "${w}" ]] || continue
    log "Joining worker ${w}"
    remote_sudo "${w}" "${join_cmd}"
  done
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
  log "Cluster status"
  remote "${CONTROL_PLANE_IP}" "kubectl get nodes -o wide"
  echo
  remote "${CONTROL_PLANE_IP}" "kubectl get pods -A"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== airgap-bootstrap.sh ==="
  log "Inventory      : ${INVENTORY}"
  log "Bundle dir     : ${BUNDLE_DIR}"
  log "K8s version    : ${K8S_MINOR_VERSION}"
  log "Control plane  : ${CONTROL_PLANE_IP}"
  log "Workers        : ${WORKERS[*]:-<none>}"
  log "Local registry : ${LOCAL_REGISTRY:-<none — loading from tarballs>}"

  check_access
  prepare_all_nodes
  init_control_plane
  configure_kubectl
  install_cni
  join_workers
  show_status

  echo
  echo "Done."
  echo "Control plane : ${CONTROL_PLANE_IP}"
  echo "Workers       : ${WORKERS[*]:-<none>}"
  echo
  echo "Run 'airgap-longhorn.sh' to install storage."
}

main "$@"
