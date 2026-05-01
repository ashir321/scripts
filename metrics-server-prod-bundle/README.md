# Production Metrics Server Bundle

This bundle deploys Metrics Server with:

- Full RBAC
- APIService registration
- proxy and no-proxy injection from `inventory.ini`
- airgap/local registry support through `local_registry=` in `inventory.ini`
- kubelet scrape settings for self-managed Kubernetes clusters
- `--kubelet-insecure-tls` for clusters using kubelet serving certificates without proper SANs

## Files

| File | Purpose |
|---|---|
| `inventory.ini` | Example inventory using your supplied proxy values |
| `metrics-server.production.template.yaml` | Main Kubernetes manifest template |
| `render-metrics-server-yaml.sh` | Reads `inventory.ini` and generates final YAML |
| `apply-metrics-server.sh` | Renders and applies the manifest |
| `kubelet-auth-check.sh` | Run on each node if Metrics Server logs show 403 Forbidden |

## Usage

```bash
unzip metrics-server-production-proxy-airgap-rbac.zip
cd metrics-server-prod-bundle
chmod +x *.sh
./render-metrics-server-yaml.sh inventory.ini
kubectl apply -f metrics-server.production.yaml
```

Or directly:

```bash
./apply-metrics-server.sh inventory.ini
```

## Airgap/local registry

Set this in `inventory.ini`:

```ini
local_registry=1.10.2.72:5000
```

The rendered image becomes:

```text
1.10.2.72:5000/metrics-server/metrics-server:v0.8.0
```

Before applying, make sure this image exists in the local registry.

## Important for your 403 Forbidden issue

Your log shows Metrics Server reaches kubelet but kubelet rejects it with `403 Forbidden`.
That usually requires fixing kubelet auth, not proxy.

On every node, kubelet should have:

```yaml
authentication:
  webhook:
    enabled: true
authorization:
  mode: Webhook
```

Check with:

```bash
./kubelet-auth-check.sh
```

Then restart kubelet if you changed kubelet config:

```bash
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

## Verify

```bash
kubectl -n kube-system rollout status deployment/metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl -n kube-system logs deploy/metrics-server --tail=80
kubectl top nodes
kubectl top pods -A
```
