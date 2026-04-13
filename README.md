# Scripts

## kubeadm init — Control Plane Bootstrap

An animated, step-by-step visualisation of what `kubeadm init` does when bootstrapping a Kubernetes control plane.

[![Open kubeadm init animation](https://img.shields.io/badge/%E2%96%B6%20Open%20Demo-kubeadm%20init%20animated-blue?style=for-the-badge)](https://ashir321.github.io/scripts/kubeadm-init-animated.html)

> **Click the badge above** to open the live animated diagram in your browser.

---

## Online bootstrap

| Script | Purpose |
|---|---|
| `bootstrap.sh` | Bootstrap a K8s cluster on internet-connected nodes |
| `enable-proxy.sh` | Configure HTTP proxy on all cluster nodes |
| `install_longhorn_kubectl.sh` | Install Longhorn storage (internet-connected) |

---

## Airgapped Kubernetes infrastructure automation

These three scripts automate a **fully airgapped** Kubernetes + Calico + Longhorn
deployment — no internet access is required on the target nodes.

### Scripts

| Script | Where to run | Purpose |
|---|---|---|
| `airgap-prep.sh` | Internet-connected machine | Download all RPMs, container images, and manifests into a `bundle/` directory |
| `airgap-bootstrap.sh` | Jump-host / bastion with SSH to nodes | Bootstrap K8s cluster entirely from the local bundle |
| `airgap-longhorn.sh` | Jump-host / bastion with SSH to nodes | Install Longhorn storage from the local bundle |

### Prerequisites

**Prep machine** (internet access required):
- RHEL / CentOS / Rocky / AlmaLinux (for `dnf download`)
- `docker` or `podman` (image pulls)
- `curl`
- Root / `sudo` privileges

**Target nodes** (airgapped — no internet needed):
- RHEL / CentOS / Rocky / AlmaLinux
- SSH access + passwordless `sudo` from the jump-host

### Step 1 — Download artifacts (internet-connected machine)

```bash
# Clone / copy this repo to the internet-connected machine
sudo ./airgap-prep.sh inventory.ini
```

This creates a `bundle/` directory containing:
```
bundle/
  rpms/containerd/    — containerd.io + container-selinux
  rpms/k8s/           — kubelet, kubeadm, kubectl
  rpms/utils/         — curl, socat, conntrack-tools, etc.
  images/             — K8s, Calico, and Longhorn images (OCI tarballs)
  manifests/          — calico.yaml, longhorn.yaml
  bundle-info.txt
  checksums.sha256
```

### Step 2 — Transfer the bundle to the airgapped environment

Copy the entire `bundle/` directory to your jump-host (the machine that has
SSH access to the K8s nodes), then update `inventory.ini`:

```ini
bundle_dir=/path/to/bundle
```

### Step 3 — Bootstrap the cluster

```bash
./airgap-bootstrap.sh inventory.ini
```

This will, for each node in `inventory.ini`:
1. Upload the RPM packages and container image tarballs via SCP
2. Disable swap, configure kernel modules and sysctl
3. Install containerd, kubelet, kubeadm, kubectl from the bundle RPMs
4. Load all container images into containerd
5. Run `kubeadm init` on the control plane (no internet pull)
6. Apply the Calico CNI manifest from the bundle
7. Join worker nodes

### Step 4 — Install Longhorn storage

```bash
./airgap-longhorn.sh inventory.ini
```

### Optional — Using a local registry

If you have a local container registry (Harbor, Docker Registry, etc.) instead
of loading images directly from tarballs, set in `inventory.ini`:

```ini
local_registry=registry.local:5000
```

When `local_registry` is set:
- `containerd` is configured to mirror `registry.k8s.io` and `docker.io` to your registry
- `kubeadm init` uses `--image-repository=registry.local:5000`
- Calico and Longhorn manifests are rewritten to reference your registry

You are responsible for pushing the images into the registry beforehand
(e.g. with `skopeo copy` or `docker tag && docker push`).

### inventory.ini — airgap variables

| Variable | Default | Description |
|---|---|---|
| `bundle_dir` | `./bundle` | Path to the bundle created by `airgap-prep.sh` |
| `local_registry` | *(empty)* | Optional local registry address (e.g. `registry.local:5000`) |
| `pause_image` | *(auto-detect)* | Override containerd sandbox (pause) image |

