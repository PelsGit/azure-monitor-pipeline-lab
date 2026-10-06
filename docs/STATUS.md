# Lab status and how to bring it back

**Status: 🅿️ PARKED** (since 5 Oct 2026, after the customer demo)

The working pipeline is **kept**, since it was the hard part to build (portal template fixes, certificate workaround).
Everything that cost money without being needed, or left credentials on homelab systems, was removed.

## What's still running

| Component | State | Approx. cost |
|---|---|---|
| VM 110 `amp-lab-k3s` (192.168.2.100), K3s, Arc agents | running, `onboot 1` | homelab power only |
| Arc cluster `arc-amp-lab` | Connected | free |
| `azure-cert-management` + `azmon-pipeline-extension` 1.7.0 | Succeeded | free |
| Pipeline `amp-portal-demo`, custom location, DCE/DCR `Aep-amp-portal-demo-*` | Succeeded | free |
| Log Analytics `law-amp-lab` (1 GB/day cap) | ingesting Proxmox syslog | **≈ €1–2/month** (≈ 10–20k filtered records/day) |
| rsyslog forward on host01/host02 (`/etc/rsyslog.d/90-amp-lab.conf`) | active | — |
| Cert-manager `-current` secret workaround | in place | — |

## What was removed

| Removed | Notes |
|---|---|
| Managed Grafana `amg-amp-lab` | ~$2.30/day. Dashboard JSON is identical to `grafana/homelab-health.json` |
| Managed Prometheus: `azuremonitor-metrics` extension, workspace `amw-amp-lab`, recording rule group | |
| Grafana role assignments (incl. orphaned RG-level Monitoring Reader) | |
| K3s namespace `monitoring` (pve-exporter, snmp-exporter, their secrets) | |
| Proxmox user `pve-exporter@pve` + token (PVEAuditor) | |
| NAS SNMP: **disabled** again (back to localhost-only) | user name `amp-snmp` remains as an inert setting |
| Portal viewer service account + token (`default/portal-viewer`) | file on the Pi deleted |

## Bring it back

### Pipeline demo only (≈ 5 minutes)
Nothing to rebuild. Run the **T-60 checklist** in [`DEMO.md`](DEMO.md) and the health check:
```bash
export KUBECONFIG=~/.kube/amp-lab.yaml
kubectl -n azure-monitor-ns get pods                       # amp-portal-demo-statefulset-0 = 3/3
kubectl get clusterissuer,bundle | grep arc-amp            # all True / Synced
ssh host01 'logger -p auth.notice -t amp-demo "test"'      # appears in law-amp-lab within ~5 min
```
If the VM was off: `qm start 110` on host01, then wait about 3 minutes for K3s and Arc.

### Plus the Grafana dashboard (≈ 20 minutes)
Follow **Rebuild** in [`GRAFANA.md`](GRAFANA.md):
1. `az monitor account create` + `az grafana create --sku-tier Standard` (Essential isn't available)
2. Metrics extension with `azure-monitor-workspace-resource-id` and `grafana-resource-id`
3. Remove the **subscription-wide** Monitoring Reader that Grafana creation grants
4. Recreate the Proxmox PVEAuditor user/token and NAS SNMPv3 (heads-up before the NAS change), and their k8s Secrets
5. `kubectl apply -f k8s/monitoring/`, then import `grafana/homelab-health.json`

### Optional: park it further
| Option | Saves | Trade-off |
|---|---|---|
| Stop the rsyslog forward (rename `90-amp-lab.conf` on both hosts) | the ≈ €1–2/month ingestion | no fresh data; re-enable before a demo and wait about 10 minutes |
| Stop VM 110 (`qm shutdown 110`) | homelab RAM/CPU (4 vCPU, 8 GB) | Arc shows *Offline*; pipeline restarts on boot (certificate workaround survives) |

## Full teardown (when the lab isn't needed anymore)
```bash
az group delete -n rg-amp-lab -y
ssh host01 'qm destroy 110 --purge'
for h in host01 host02; do ssh $h 'rm /etc/rsyslog.d/90-amp-lab.conf && systemctl restart rsyslog'; done
```
