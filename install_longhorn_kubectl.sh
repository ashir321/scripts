#!/usr/bin/env bash
set -euo pipefail

INVENTORY="${1:-inventory.ini}"

# Longhorn release tag
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.11.1}"

# Default Longhorn data path
LONGHORN_DATA_PATH="${LONGHORN_DATA_PATH:-/var/lib/longhorn}"

# Expose UI through NodePort
LONGHORN_UI_NODEPORT="${LONGHORN_UI_NODEPORT:-30080}"

# Default Longhorn replica count
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

HTTP_PROXY_VAR="$(get_var HTTP_PROXY)"
HTTPS_PROXY_VAR="$(get_var HTTPS_PROXY)"
NO_PROXY_VAR="$(get_var NO_PROXY)"
http_proxy_var="$(get_var http_proxy)"
https_proxy_var="$(get_var https_proxy)"
no_proxy_var="$(get_var no_proxy)"

mapfile -t CONTROL_PLANES < <(get_group_hosts control_plane)
mapfile -t WORKERS < <(get_group_hosts workers)

CONTROL_PLANE_IP="${CONTROL_PLANES[0]:-}"

if [[ -z "${SSH_USER}" || -z "${SSH_KEY}" || -z "${CONTROL_PLANE_IP}" ]]; then
  echo "inventory.ini is missing required values: ssh_user, ssh_key, or control_plane"
  exit 1
fi

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=120
)

remote() {
  local host="$1"
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

remote_sudo() {
  local host="$1"
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "sudo bash -lc $(printf '%q' "$*")"
}

proxy_exports() {
  cat <<EOF
export HTTP_PROXY='${HTTP_PROXY_VAR:-}'
export HTTPS_PROXY='${HTTPS_PROXY_VAR:-}'
export NO_PROXY='${NO_PROXY_VAR:-}'
export http_proxy='${http_proxy_var:-${HTTP_PROXY_VAR:-}}'
export https_proxy='${https_proxy_var:-${HTTPS_PROXY_VAR:-}}'
export no_proxy='${no_proxy_var:-${NO_PROXY_VAR:-}}'
EOF
}

check_access() {
  local nodes=("${CONTROL_PLANE_IP}" "${WORKERS[@]}")
  for n in "${nodes[@]}"; do
    log "Checking SSH and passwordless sudo on ${n}"
    remote "${n}" "id >/dev/null"
    remote "${n}" "sudo -n true"
  done
}

node_prereq_script() {
  cat <<'NODE_PREREQ'
#!/usr/bin/env bash
set -euo pipefail

LONGHORN_DATA_PATH="${1:-/var/lib/longhorn}"

echo "[INFO] Installing Longhorn prerequisites"

OS_ID=""
OS_LIKE=""
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
fi

install_pkgs_rpm() {
  if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  else
    PKG_MGR="yum"
  fi

  ${PKG_MGR} makecache -y || true
  ${PKG_MGR} install -y \
    iscsi-initiator-utils \
    nfs-utils \
    cryptsetup \
    device-mapper-persistent-data \
    util-linux \
    curl \
    jq \
    tar \
    gzip \
    findutils \
    gawk \
    grep \
    coreutils
}

install_pkgs_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    open-iscsi \
    nfs-common \
    cryptsetup \
    util-linux \
    curl \
    jq \
    tar \
    gzip \
    findutils \
    gawk \
    grep \
    coreutils
}

case "${OS_ID}:${OS_LIKE}" in
  ubuntu:*|debian:*|*:debian*)
    install_pkgs_deb
    ISCSI_SERVICE="iscsid"
    ;;
  rhel:*|centos:*|rocky:*|almalinux:*|ol:*|amzn:*|*:rhel*|*:fedora*)
    install_pkgs_rpm
    ISCSI_SERVICE="iscsid"
    mkdir -p /etc/iscsi
    if [[ ! -s /etc/iscsi/initiatorname.iscsi ]] && command -v iscsi-iname >/dev/null 2>&1; then
      echo "InitiatorName=$(iscsi-iname)" >/etc/iscsi/initiatorname.iscsi
    fi
    ;;
  *)
    echo "[ERROR] Unsupported OS: ${OS_ID} ${OS_LIKE}"
    exit 1
    ;;
esac

mkdir -p /etc/modules-load.d
cat >/etc/modules-load.d/longhorn.conf <<'EOF'
iscsi_tcp
dm_crypt
EOF

modprobe iscsi_tcp || true
modprobe dm_crypt || true

systemctl enable --now "${ISCSI_SERVICE}" || true
systemctl restart "${ISCSI_SERVICE}" || true

if systemctl list-unit-files | awk '{print $1}' | grep -qx iscsi.service; then
  systemctl enable --now iscsi || true
fi

mkdir -p "${LONGHORN_DATA_PATH}"
chmod 755 "${LONGHORN_DATA_PATH}"

command -v iscsiadm >/dev/null 2>&1 || {
  echo "[ERROR] iscsiadm not found"
  exit 1
}

systemctl is-active --quiet "${ISCSI_SERVICE}" || {
  echo "[ERROR] ${ISCSI_SERVICE} is not active"
  exit 1
}

echo "[INFO] Longhorn prerequisites ready on $(hostname -f 2>/dev/null || hostname)"
echo "[INFO] Data path: ${LONGHORN_DATA_PATH}"
NODE_PREREQ
}

prepare_node() {
  local host="$1"
  log "Preparing Longhorn prerequisites on ${host}"
  node_prereq_script | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
    "sudo bash -s -- '${LONGHORN_DATA_PATH}'"
}

prepare_all_nodes() {
  prepare_node "${CONTROL_PLANE_IP}"
  for w in "${WORKERS[@]}"; do
    prepare_node "${w}"
  done
}

install_longhorn_manifest() {
  log "Installing Longhorn ${LONGHORN_VERSION} on ${CONTROL_PLANE_IP}"

  local proxy_env
  proxy_env="$(proxy_exports)"

  remote "${CONTROL_PLANE_IP}" "
    ${proxy_env}
    kubectl get ns longhorn-system >/dev/null 2>&1 || kubectl create ns longhorn-system
    curl -fsSL 'https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml' -o /tmp/longhorn.yaml
  "

  log "Patching Longhorn manifest"
  remote "${CONTROL_PLANE_IP}" "
    python3 - <<'PY'
from pathlib import Path

p = Path('/tmp/longhorn.yaml')
text = p.read_text()

text = text.replace(
    'default-data-path: /var/lib/longhorn',
    'default-data-path: ${LONGHORN_DATA_PATH}'
)

text = text.replace(
    'numberOfReplicas: \"3\"',
    'numberOfReplicas: \"${LONGHORN_DEFAULT_REPLICA_COUNT}\"'
)

p.write_text(text)
PY
  "

  remote "${CONTROL_PLANE_IP}" "kubectl apply -f /tmp/longhorn.yaml"
}

expose_longhorn_ui_nodeport() {
  log "Exposing Longhorn UI via NodePort ${LONGHORN_UI_NODEPORT}"

  remote "${CONTROL_PLANE_IP}" "
    kubectl -n longhorn-system patch svc longhorn-frontend --type merge -p '
{
  \"spec\": {
    \"type\": \"NodePort\",
    \"ports\": [
      {
        \"name\": \"http\",
        \"port\": 80,
        \"protocol\": \"TCP\",
        \"targetPort\": 8000,
        \"nodePort\": ${LONGHORN_UI_NODEPORT}
      }
    ]
  }
}'
  "
}

set_default_storageclass() {
  log "Making Longhorn the default StorageClass"
  remote "${CONTROL_PLANE_IP}" "
    kubectl patch storageclass longhorn \
      -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'
  " || true
}

wait_for_longhorn() {
  log "Waiting for Longhorn components"
  remote "${CONTROL_PLANE_IP}" "
    kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=15m || true
    kubectl -n longhorn-system rollout status deploy/longhorn-ui --timeout=15m || true
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

    echo
    echo '=== longhorn StorageClass ==='
    kubectl get sc longhorn -o yaml | sed -n '/parameters:/,/reclaimPolicy:/p'
  "
}

print_next_steps() {
  cat <<EOF

Done.

Longhorn version : ${LONGHORN_VERSION}
Control plane    : ${CONTROL_PLANE_IP}
Workers          : ${WORKERS[*]}
Data path        : ${LONGHORN_DATA_PATH}
Default replicas : ${LONGHORN_DEFAULT_REPLICA_COUNT}
UI NodePort      : ${LONGHORN_UI_NODEPORT}

Open UI:
  http://${CONTROL_PLANE_IP}:${LONGHORN_UI_NODEPORT}
EOF

  for w in "${WORKERS[@]}"; do
    echo "  http://${w}:${LONGHORN_UI_NODEPORT}"
  done

  cat <<EOF

Verify:
  kubectl -n longhorn-system get pods -o wide
  kubectl -n longhorn-system get svc longhorn-frontend
  kubectl get sc longhorn -o yaml | grep -A3 numberOfReplicas
EOF
}

main() {
  check_access
  prepare_all_nodes
  install_longhorn_manifest
  expose_longhorn_ui_nodeport
  set_default_storageclass
  wait_for_longhorn
  show_status
  print_next_steps
}

main "$@"
