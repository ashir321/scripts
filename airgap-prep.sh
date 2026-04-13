#!/usr/bin/env bash
# airgap-prep.sh — Run on an internet-connected machine to download all
# artifacts needed for an airgapped Kubernetes + Calico + Longhorn deployment.
#
# Prerequisites (prep machine — must be RHEL/CentOS/Rocky/AlmaLinux):
#   - dnf (RPM downloads)
#   - docker or podman (image pulls)
#   - curl
#   - root / sudo privileges (for dnf download and repo setup)
#
# Usage:
#   sudo ./airgap-prep.sh [inventory.ini]
#
# Outputs a bundle/ directory (or the path set by bundle_dir in inventory.ini):
#   bundle/
#     rpms/containerd/   — containerd.io + container-selinux RPMs
#     rpms/k8s/          — kubelet, kubeadm, kubectl RPMs
#     rpms/utils/        — curl, conntrack-tools, socat, etc.
#     images/            — container images saved as OCI tarballs
#     manifests/         — calico.yaml, longhorn.yaml
#     bundle-info.txt    — version metadata
#     checksums.sha256
#
# Transfer the entire bundle/ directory to the airgapped environment, then run
# airgap-bootstrap.sh from the same working directory.
set -euo pipefail

INVENTORY="${1:-inventory.ini}"

log() {
  echo
  echo "[$(date '+%F %T')] $*"
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

# ---------------------------------------------------------------------------
# Configuration (sourced from inventory.ini with sensible defaults)
# ---------------------------------------------------------------------------
K8S_MINOR_VERSION="$(get_var k8s_minor_version 'v1.33')"
CALICO_URL="$(get_var calico_url \
  'https://raw.githubusercontent.com/projectcalico/calico/v3.31.4/manifests/calico.yaml')"
LONGHORN_VERSION="$(get_var LONGHORN_VERSION 'v1.11.1')"
BUNDLE_DIR="$(get_var bundle_dir './bundle')"

RPMS_DIR="${BUNDLE_DIR}/rpms"
IMAGES_DIR="${BUNDLE_DIR}/images"
MANIFESTS_DIR="${BUNDLE_DIR}/manifests"

# ---------------------------------------------------------------------------
# Detect prerequisites
# ---------------------------------------------------------------------------
detect_tools() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_CLI="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI="podman"
  else
    echo "ERROR: docker or podman is required to pull container images."
    exit 1
  fi

  if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    echo "ERROR: dnf or yum is required to download RPMs."
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Repository setup
# ---------------------------------------------------------------------------
setup_repos() {
  log "Configuring Kubernetes ${K8S_MINOR_VERSION} repo on prep machine"
  cat >/etc/yum.repos.d/kubernetes-airgap-prep.repo <<REPO
[kubernetes-airgap-prep]
name=Kubernetes ${K8S_MINOR_VERSION} (airgap prep)
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR_VERSION}/rpm/repodata/repomd.xml.key
REPO

  log "Configuring Docker CE (containerd) repo on prep machine"
  if ! ${PKG_MGR} repolist 2>/dev/null | grep -q '^docker-ce-stable'; then
    ${PKG_MGR} config-manager --add-repo \
      https://download.docker.com/linux/centos/docker-ce.repo
  fi

  ${PKG_MGR} makecache -y
}

# ---------------------------------------------------------------------------
# RPM download
# ---------------------------------------------------------------------------
download_rpms() {
  log "Downloading containerd RPMs → ${RPMS_DIR}/containerd/"
  mkdir -p "${RPMS_DIR}/containerd"
  ${PKG_MGR} download --resolve --destdir="${RPMS_DIR}/containerd" \
    containerd.io container-selinux

  log "Downloading Kubernetes RPMs → ${RPMS_DIR}/k8s/"
  mkdir -p "${RPMS_DIR}/k8s"
  ${PKG_MGR} download --resolve --destdir="${RPMS_DIR}/k8s" \
    kubelet kubeadm kubectl

  log "Downloading utility RPMs → ${RPMS_DIR}/utils/"
  mkdir -p "${RPMS_DIR}/utils"
  # Best-effort; some may already be installed on target nodes
  ${PKG_MGR} download --resolve --destdir="${RPMS_DIR}/utils" \
    curl ca-certificates gnupg2 iproute iptables ebtables ethtool \
    socat conntrack-tools tar bash-completion vim dnf-plugins-core \
    cri-tools kubernetes-cni 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Container image helpers
# ---------------------------------------------------------------------------
pull_and_save() {
  local image="$1"
  local label="${2:-}"
  local safe_name
  # Replace / and : with __ for filename
  safe_name="$(echo "${image}" | sed 's|[/:]|__|g')"
  local out="${IMAGES_DIR}/${safe_name}.tar"

  if [[ -f "${out}" ]]; then
    echo "  [cached] ${image}"
    return
  fi

  echo "  Pulling  ${image}"
  ${CONTAINER_CLI} pull "${image}" >/dev/null
  echo "  Saving   ${image} → $(basename "${out}")"
  ${CONTAINER_CLI} save "${image}" -o "${out}"
}

extract_images_from_manifest() {
  local manifest="$1"
  grep -E '^\s+image:\s+' "${manifest}" \
    | awk '{print $NF}' \
    | tr -d '"'"'" \
    | sort -u
}

# ---------------------------------------------------------------------------
# K8s control-plane images
# ---------------------------------------------------------------------------
pull_k8s_images() {
  log "Pulling Kubernetes control-plane images"

  # Install kubeadm on prep machine (already available from the repo above)
  if ! command -v kubeadm >/dev/null 2>&1; then
    log "Installing kubeadm on prep machine to resolve image list"
    ${PKG_MGR} install -y kubeadm
  fi

  local images
  # Try with explicit kubernetes-version, fall back to installed version
  if images="$(kubeadm config images list \
      --kubernetes-version "${K8S_MINOR_VERSION}.0" 2>/dev/null)"; then
    true
  elif images="$(kubeadm config images list 2>/dev/null)"; then
    true
  else
    echo "ERROR: kubeadm config images list failed."
    exit 1
  fi

  while IFS= read -r img; do
    [[ -n "${img}" ]] || continue
    pull_and_save "${img}"
  done <<<"${images}"
}

# ---------------------------------------------------------------------------
# Manifest download + image pull
# ---------------------------------------------------------------------------
download_manifests() {
  log "Downloading Calico manifest → ${MANIFESTS_DIR}/calico.yaml"
  curl -fsSL "${CALICO_URL}" -o "${MANIFESTS_DIR}/calico.yaml"

  log "Downloading Longhorn ${LONGHORN_VERSION} manifest → ${MANIFESTS_DIR}/longhorn.yaml"
  curl -fsSL \
    "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml" \
    -o "${MANIFESTS_DIR}/longhorn.yaml"
}

pull_manifest_images() {
  local manifest="$1"
  local label="$2"
  log "Pulling images from ${label} manifest"
  while IFS= read -r img; do
    [[ -n "${img}" ]] || continue
    pull_and_save "${img}" "${label}" || \
      echo "  [warn] Could not pull ${img} — skipping"
  done < <(extract_images_from_manifest "${manifest}")
}

# ---------------------------------------------------------------------------
# Bundle metadata
# ---------------------------------------------------------------------------
write_bundle_info() {
  cat >"${BUNDLE_DIR}/bundle-info.txt" <<INFO
k8s_minor_version=${K8S_MINOR_VERSION}
longhorn_version=${LONGHORN_VERSION}
calico_url=${CALICO_URL}
created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
INFO
}

generate_checksums() {
  log "Generating checksums → ${BUNDLE_DIR}/checksums.sha256"
  find "${BUNDLE_DIR}" -type f ! -name 'checksums.sha256' \
    -exec sha256sum {} + >"${BUNDLE_DIR}/checksums.sha256"
}

# ---------------------------------------------------------------------------
# Cleanup temp repo file
# ---------------------------------------------------------------------------
cleanup() {
  rm -f /etc/yum.repos.d/kubernetes-airgap-prep.repo
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== airgap-prep.sh ==="
  log "Inventory  : ${INVENTORY}"
  log "Bundle dir : ${BUNDLE_DIR}"
  log "K8s version: ${K8S_MINOR_VERSION}"
  log "Longhorn   : ${LONGHORN_VERSION}"
  echo

  detect_tools
  mkdir -p "${RPMS_DIR}" "${IMAGES_DIR}" "${MANIFESTS_DIR}"

  setup_repos
  download_rpms
  download_manifests
  pull_k8s_images
  pull_manifest_images "${MANIFESTS_DIR}/calico.yaml"  "Calico"
  pull_manifest_images "${MANIFESTS_DIR}/longhorn.yaml" "Longhorn"

  write_bundle_info
  generate_checksums

  log "Bundle complete."
  echo
  echo "Contents:"
  find "${BUNDLE_DIR}" -type f | sort
  echo
  echo "Next steps:"
  echo "  1. Copy '${BUNDLE_DIR}/' to the airgapped environment."
  echo "  2. Update inventory.ini: set bundle_dir=<path to bundle>"
  echo "  3. Run:  ./airgap-bootstrap.sh [inventory.ini]"
}

main "$@"
