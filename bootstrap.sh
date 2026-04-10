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
K8S_MINOR_VERSION="$(get_var k8s_minor_version)"
POD_CIDR="$(get_var pod_cidr)"
CALICO_URL="$(get_var calico_url)"

mapfile -t CONTROL_PLANES < <(get_group_hosts control_plane)
mapfile -t WORKERS < <(get_group_hosts workers)

CONTROL_PLANE_IP="${CONTROL_PLANES[0]:-}"

if [[ -z "${SSH_USER}" || -z "${SSH_KEY}" || -z "${CONTROL_PLANE_IP}" ]]; then
  echo "inventory.ini is missing required values."
  exit 1
fi

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

remote() {
  local host="$1"
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

remote_sudo() {
  local host="$1"
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "sudo bash -lc '$*'"
}

check_access() {
  local nodes=("${CONTROL_PLANE_IP}" "${WORKERS[@]}")
  for n in "${nodes[@]}"; do
    log "Checking SSH and passwordless sudo on ${n}"
    remote "${n}" "id >/dev/null"
    remote "${n}" "sudo -n true"
  done
}

node_prep_script() {
  cat <<'NODE_PREP'
#!/usr/bin/env bash
set -euo pipefail

K8S_MINOR_VERSION="${1}"
NODE_ROLE="${2}"

echo "[INFO] Preparing node for Kubernetes (${NODE_ROLE})"

install_containerd() {
  if dnf list --available containerd >/dev/null 2>&1; then
    dnf install -y containerd
    return
  fi

  if ! dnf repolist | grep -q '^docker-ce-stable'; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  fi

  dnf install -y containerd.io
}

swapoff -a || true
if grep -Eq '^[^#].*\sswap\s' /etc/fstab; then
  cp -a /etc/fstab /etc/fstab.bak.$(date +%F-%H%M%S)
  sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab
fi

if command -v setenforce >/dev/null 2>&1; then
  setenforce 0 || true
fi
if [[ -f /etc/selinux/config ]]; then
  sed -ri 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
fi

cat >/etc/modules-load.d/k8s.conf <<'MODS'
overlay
br_netfilter
MODS

modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL

sysctl --system >/dev/null

dnf makecache -y
dnf install -y \
  curl \
  ca-certificates \
  gnupg2 \
  iproute \
  iptables \
  ebtables \
  ethtool \
  socat \
  conntrack-tools \
  tar \
  bash-completion \
  vim \
  container-selinux \
  dnf-plugins-core

install_containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

cat >/etc/crictl.yaml <<'CRICTL'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
CRICTL

cat >/etc/yum.repos.d/kubernetes.repo <<REPO
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
REPO

dnf install -y --disableexcludes=kubernetes kubelet kubeadm kubectl
systemctl enable --now kubelet

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=6443/tcp || true
  firewall-cmd --permanent --add-port=2379-2380/tcp || true
  firewall-cmd --permanent --add-port=10250/tcp || true
  firewall-cmd --permanent --add-port=10257/tcp || true
  firewall-cmd --permanent --add-port=10259/tcp || true
  firewall-cmd --reload || true
fi

echo "[INFO] Node prep complete"
NODE_PREP
}

prepare_node() {
  local host="$1"
  local role="$2"
  log "Preparing ${role} node ${host}"
  node_prep_script | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "sudo bash -s -- '${K8S_MINOR_VERSION}' '${role}'"
}

prepare_all_nodes() {
  prepare_node "${CONTROL_PLANE_IP}" control-plane
  for w in "${WORKERS[@]}"; do
    prepare_node "${w}" worker
  done
}

init_control_plane() {
  log "Pre-pulling images on control plane"
  remote_sudo "${CONTROL_PLANE_IP}" "kubeadm config images pull"

  log "Initializing control plane on ${CONTROL_PLANE_IP}"
  remote_sudo "${CONTROL_PLANE_IP}" "
    if [[ ! -f /etc/kubernetes/admin.conf ]]; then
      kubeadm init \
        --apiserver-advertise-address='${CONTROL_PLANE_IP}' \
        --pod-network-cidr='${POD_CIDR}'
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

install_cni() {
  log "Installing Calico"
  remote "${CONTROL_PLANE_IP}" "kubectl apply -f '${CALICO_URL}'"
}

join_workers() {
  log "Creating join command"
  local join_cmd
  join_cmd="$(remote_sudo "${CONTROL_PLANE_IP}" "kubeadm token create --print-join-command")"

  for w in "${WORKERS[@]}"; do
    log "Joining worker ${w}"
    remote_sudo "${w}" "${join_cmd}"
  done
}

show_status() {
  log "Cluster status"
  remote "${CONTROL_PLANE_IP}" "kubectl get nodes -o wide"
  echo
  remote "${CONTROL_PLANE_IP}" "kubectl get pods -A"
}

main() {
  check_access
  prepare_all_nodes
  init_control_plane
  configure_kubectl
  install_cni
  join_workers
  show_status

  echo
  echo "Done."
  echo "Control plane: ${CONTROL_PLANE_IP}"
  echo "Workers: ${WORKERS[*]}"
}

main "$@"

