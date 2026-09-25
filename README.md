# Azure Monitor pipeline – homelab crash-course lab

Hands-on lab: ship homelab syslog + OpenTelemetry logs to Azure Log Analytics through an
**Azure Monitor pipeline** running on an Arc-enabled K3s cluster, with KQL transformations at the edge.

```
Proxmox host01/host02 ── syslog UDP 514 ─┐
                                         ├─► K3s VM 192.168.2.100 (Azure Arc)
telemetrygen (in-cluster) ─ OTLP 4317 ───┘     └─ Azure Monitor pipeline pod
                                                    ├─ MicrosoftSyslog processor
                                                    ├─ KQL transforms (filter / mask)
                                                    └─ exporter (managed identity)
                                                           ▼
                                   DCE → DCR → Log Analytics (Syslog, OTelLogs_CL)
```

## Components
| Where | What |
|---|---|
| Homelab | Debian 13 VM, K3s v1.33, Arc agents, `microsoft.certmanagement`, `microsoft.monitor.pipelinecontroller` (1.7.0) |
| Azure (`rg-amp-lab`, West Europe) | Log Analytics (1 GB/day cap), DCE, DCR, custom location, `Microsoft.Monitor/pipelineGroups` |

## Transformations (edge, before ingestion = before you pay)
* **Syslog:** `source | where SeverityLevel != 'debug' | where not(ProcessName in ('pvestatd','CRON','systemd-timesyncd'))`
* **OTLP:** `source | where SeverityText != 'DEBUG' | extend Body = replace_string(Body, 'password=hunter2', 'password=***')`

Result: 0 debug/noisy records in `Syslog`; all 20 INFO OTLP records arrived with the password masked, all 20 DEBUG records were dropped.

## Deploy order
1. K3s → `az connectedk8s connect` → `enable-features custom-locations`
2. `az k8s-extension create` certmanagement, then pipelinecontroller (`--release-namespace amp`)
3. `az customlocation create`, DCE, `OTelLogs_CL` table
4. `infra/dcr.json` (ARM), then role **Monitoring Metrics Publisher** on the DCR for the extension identity
5. `infra/pipeline.json` with `infra/pipeline.parameters.json` (copy from the `.example`)
6. `kubectl apply -f k8s/expose.yaml` (LAN LoadBalancer), `k8s/otel-generator.yaml`
7. Point sources at 192.168.2.100:514/udp (`scripts/rsyslog-forward.conf`)

## Lessons learned / gotchas
1. **Pipeline pod stuck in `Init:0/1`** – cert-manager extension never created `arc-amp-*-root-ca-current`
   secrets / rotation labels → ClusterIssuers `ErrGetKeyPair`, trust bundles `SourceNotFound`.
   Lab workaround: `scripts/fix-certmanager-ca.sh` (does not rotate).
2. **Receivers default to mTLS.** UDP syslog must have *no* `tlsConfiguration`
   (`TlsNotSupportedForUdpTransport`); OTLP uses `mode: disabled` for this lab.
3. **Syslog 400 Bad Request** – the exporter's `Microsoft-Syslog-FullyFormed` is internally sent as
   stream `LINUX_SYSLOGS_FULLY_FORMED`. The DCR data flow must list `Microsoft-Syslog-FullyFormed` as its
   input stream with output `Microsoft-Syslog`; with `Microsoft-Syslog` as input every batch fails.
   DCR changes take several minutes to propagate. Tip: the extension ships a forensics script in the
   `azure-monitor-pipeline-forensics` ConfigMap; its rendered collector config shows the real stream name.
4. The exporter authenticates with the extension's **managed identity** – no secrets on the edge.
5. Extension release train `Preview` was used for OTLP (preview feature); Syslog/CEF is GA.

## Useful KQL
See `docs/queries.kql`.

## Teardown
```bash
az group delete -n rg-amp-lab -y          # all Azure resources
qm destroy 110 --purge                     # on the Proxmox node hosting the VM
rm /etc/rsyslog.d/90-amp-lab.conf && systemctl restart rsyslog   # each Proxmox host
```
