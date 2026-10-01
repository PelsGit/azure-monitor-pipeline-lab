# Configure Azure Monitor pipeline in the Azure portal: step-by-step

This guide walks you through configuring **Azure Monitor pipeline with the Azure portal** on the
homelab's Arc-enabled K3s cluster. It follows the official docs:

- [Configure Azure Monitor pipeline](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/pipeline-configure) (prerequisites, cert-manager, verification)
- [Configure Azure Monitor pipeline with the Azure portal](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/pipeline-configure-portal)

> **Status (checked 1 Oct 2026):** all prerequisites in Part A are **already completed** in the homelab.
> You start at **Part B**. Lab-specific additions that aren't in the docs are marked 🏠.

```mermaid
flowchart LR
  subgraph DONE["✅ Part A: prerequisites (done)"]
    A1[Resource providers] --> A2[K3s VM + Arc] --> A3[Custom locations] --> A4[cert-manager ext] --> A5[Log Analytics]
  end
  subgraph YOU["👉 Part B–E: you, in the portal"]
    B1[Create pipeline<br/>Basics] --> B2[Dataflows<br/>+ transformation] --> B3[Review + create] --> B4[Expose + send data] --> B5[Verify]
  end
  DONE --> YOU
```

---

## Part A: Prerequisites (completed ✅)

| # | Prerequisite (official docs) | Homelab value | Status |
|---|---|---|---|
| A1 | Resource providers `Microsoft.Insights`, `Microsoft.Monitor` registered | Also registered: `Microsoft.Kubernetes`, `Microsoft.KubernetesConfiguration`, `Microsoft.ExtendedLocation`, `Microsoft.OperationalInsights` | ✅ Registered |
| A2 | Arc-enabled Kubernetes cluster with an external IP | `arc-amp-lab`, K3s `v1.33.13+k3s2` (supported distro), agent 1.37.3, VM 110 `amp-lab-k3s` at **192.168.2.100** (Proxmox host01) | ✅ Connected |
| A3 | Custom locations enabled on the cluster | `customLocations.enabled: true` (cluster-connect also enabled) | ✅ Enabled |
| A4 | Certificate Manager extension installed (step 2 of the setup flow) | `azure-cert-management`, type `microsoft.certmanagement`, version 1.2.0 | ✅ Succeeded |
| A5 | Log Analytics workspace | `law-amp-lab` in `rg-amp-lab` (West Europe), daily cap 1 GB, retention 30 days | ✅ Created |
| A6 | (Optional) custom table | Not needed: we use the built-in `Syslog` table | n/a |
| 🏠 | Syslog sources | Proxmox host01 and host02 forward `*.info` + auth via `/etc/rsyslog.d/90-amp-lab.conf` → `192.168.2.100:514/udp`; test script `amp-send-test` on the VM | ✅ Ready |
| 🏠 | Clean slate | Previous CLI-built pipeline, pipeline extension, custom location, DCR, DCE and the `amp` namespace were removed; nothing listens on 514/4317 | ✅ Reset |

**Not pre-created on purpose:** the portal flow creates the **pipeline extension, custom location, DCR and
DCE** for you. That's the part you're learning.

**Where to check in the portal:**
- *Azure Arc → Kubernetes clusters → `arc-amp-lab`* → Overview: **Connected**.
- *Extensions* tab: only `azure-cert-management` is listed (plus a system diagnostics extension, if present).

---

## Part B: Create the pipeline (portal)

### B1. Start the creation flow
Choose **one** of these:
- Portal search **"Azure Monitor pipelines"** → **+ Create**, or
- **Azure Arc → Kubernetes clusters → `arc-amp-lab` → Extensions → + Add → Azure Monitor pipeline extension**.

### B2. Basics tab

| Field | Enter | Why |
|---|---|---|
| Instance name | `amp-portal-demo` | Must be unique in the subscription; also becomes the pod/service prefix |
| Subscription | `ME-MngEnv224247-rutgerpels-1` | |
| Resource group | `rg-amp-lab` | Keeps teardown to one command |
| Cluster name | `arc-amp-lab` | |
| Custom location | let the portal create one, or name it `cl-amp-portal` | Maps an Azure "location" to a namespace on your cluster |
| Enable transport security (TLS) | **Unchecked** | UDP syslog can't use TLS; keeps the demo simple |
| Require client authentication within cluster | **Unchecked** | mTLS isn't needed for the demo |

→ **Next: Dataflows**

### B3. Dataflows tab → **+ Add dataflow**

| Field | Enter |
|---|---|
| Name | `proxmox-syslog` |
| Source type | `Syslog` |
| Port | `514` |
| Protocol | `UDP` |
| Format | both `5424` and `3164` (Proxmox's rsyslog sends 5424; `logger` can send either) |
| Collect messages with PRI header | enabled (default) |
| Log Analytics workspace | `law-amp-lab` |
| Table | `Syslog` |
| Table name | `Syslog` (must match Table) |

**Add Data Transformations** → template **Custom**, paste:

```kusto
source
| where SeverityLevel != 'debug'
| where ProcessName !in ('pvestatd', 'CRON', 'systemd-timesyncd', 'postfix')
```

Select **Check KQL syntax** and make sure it passes (it also validates against the `Syslog` schema), then **Save**.

> Optional second dataflow for OTLP (preview): source type `OTLP`, port `4317`, custom table, only
> `TimeGenerated`, `SeverityText` and `Body` are available in the portal. Skip it for a first run.

### B4. Review + create
Select **Create**. Deployment takes **several minutes**: Azure installs the pipeline extension, creates the
custom location, DCE, DCR and the pipeline instance, then waits for the pod to be healthy.

```mermaid
sequenceDiagram
  actor You
  participant Portal
  participant ARM as Azure
  participant Arc as Arc agents
  participant Pod as Pipeline pod
  You->>Portal: Create
  Portal->>ARM: extension + custom location + DCE + DCR + pipeline
  ARM->>Arc: config
  Arc->>Pod: operator builds StatefulSet, Services, certs
  Pod-->>ARM: healthy → Succeeded
```

> ⚠️ **Known issue in this lab**: with cert-management 1.2.0 + pipeline 1.7.0, the deployment may hang
> because the `arc-amp-*-root-ca-current` secrets aren't created. If the deployment stays *Running*
> for more than about 15 minutes, see **Part F**.

---

## Part C: Make the pipeline reachable from the LAN 🏠

The operator creates **ClusterIP** services, which are only reachable inside the cluster. The docs use a Traefik gateway
with a cloud LoadBalancer. On a homelab K3s, the built-in ServiceLB is simpler. Run from a machine with the kubeconfig:

```bash
export KUBECONFIG=~/.kube/amp-lab.yaml      # kubeconfig for the lab cluster
NS=$(kubectl get pods -A -l pipeline=amp-portal-demo -o jsonpath='{.items[0].metadata.namespace}')
kubectl -n $NS apply -f - <<EOF
apiVersion: v1
kind: Service
metadata: {name: amp-portal-demo-lan}
spec:
  type: LoadBalancer
  selector: {pipeline: amp-portal-demo}
  ports:
  - {name: syslog-udp, port: 514, targetPort: 514, protocol: UDP}
EOF
kubectl -n $NS get svc amp-portal-demo-lan     # EXTERNAL-IP should be 192.168.2.100
```

The Proxmox hosts are already pointed at `192.168.2.100:514/udp`, so data starts flowing straight away.

---

## Part D: Send test data

From the VM (`ssh amplab@192.168.2.100`):

```bash
amp-send-test 192.168.2.100     # 5 × INFO (kept) + 5 × DEBUG (should be dropped by your transform)
```

Or from a Proxmox host: `logger -t amp-demo "hello from $(hostname)"`.

---

## Part E: Verify (official checks + lab checks)

**E1. Cluster components:** *Arc cluster `arc-amp-lab` → Kubernetes resources → Services and ingresses*.
Expect `amp-portal-demo-service` (and, per docs, `amp-portal-demo-external-service`).

**E2. Heartbeat** (every minute; `OSMajorVersion` = pipeline name). In *law-amp-lab → Logs*:
```kusto
Heartbeat
| where OSMajorVersion == "amp-portal-demo"
| summarize LastBeat = max(TimeGenerated) by Computer, OSMajorVersion
```

**E3. Data arrived** (allow 5–10 minutes for first ingestion):
```kusto
Syslog
| where TimeGenerated > ago(30m)
| summarize Records = count() by Computer, ProcessName
| order by Records desc
```

**E4. Transformation works** (both should return **0**):
```kusto
Syslog | where TimeGenerated > ago(30m) | where SeverityLevel == 'debug' | count
Syslog | where TimeGenerated > ago(30m) | where ProcessName == 'postfix' | count
```

**E5. See what the portal built for you:** open *Monitor → Data Collection Rules* and find the new DCR. In its
**JSON view**, look at `dataFlows` (expect stream `Microsoft-Syslog-FullyFormed` → `Microsoft-Syslog`), then
check *Access control* (the extension's identity has **Monitoring Metrics Publisher**). Compare it with
`infra/dcr.json` from the CLI build.

---

## Part F: Troubleshooting

```mermaid
flowchart TD
  S{"Deployment stuck / no data?"} --> P{"kubectl get pods -A -l pipeline=amp-portal-demo<br/>Running 3/3?"}
  P -- "Init:0/1 or timeout" --> C["kubectl get clusterissuer,bundle<br/>ErrGetKeyPair / SourceNotFound?"]
  C -- yes --> FIX["bash scripts/fix-certmanager-ca.sh<br/>then delete the pipeline pod"]
  P -- "Running" --> L{"collector logs:<br/>export.failed?"}
  L -- "400" --> D["DCR stream mismatch → run forensics script"]
  L -- "403" --> R["role on DCR missing / still propagating"]
  L -- "none" --> W["wait; check source → 192.168.2.100:514 (Part C)"]
```

| Symptom | Check | Fix |
|---|---|---|
| Deployment *Running* for more than 15 min, pod `Init:0/1` | `kubectl get clusterissuer,bundle` → `ErrGetKeyPair: secrets "arc-amp-root-ca-current" not found` | `bash scripts/fix-certmanager-ca.sh`, then `kubectl -n <ns> delete pod -l pipeline=amp-portal-demo`. Copies the root CAs to `-current` and adds the rotation label. **Demo-only**; seen with cert-mgmt 1.2.0 + pipeline 1.7.0 on two clusters; not confirmed as a product defect. |
| Exports fail | `kubectl -n <ns> logs <pod> -c collector \| grep export.failed` | Run the forensics script: `kubectl -n <ns> get cm azure-monitor-pipeline-forensics -o go-template='{{ index .data "azure-monitor-pipeline-forensics.sh" }}' > f.sh && bash f.sh -n <ns> -p amp-portal-demo` |
| No data, no errors | `kubectl -n <ns> get svc` | Make sure Part C's LoadBalancer exists and shows `192.168.2.100` |
| Operator `CrashLoopBackOff` | the doc's troubleshooting section | Cert-management extension missing (already installed here) |

---

## Part G: Clean up (back to the Part A baseline)

```bash
# Azure: remove what the portal created (keeps Arc, cert-manager, workspace)
az resource delete -g rg-amp-lab -n amp-portal-demo --resource-type Microsoft.Monitor/pipelineGroups
az customlocation delete -g rg-amp-lab -n <custom-location> -y
az k8s-extension delete -g rg-amp-lab --cluster-name arc-amp-lab --cluster-type connectedClusters -n <pipeline-extension> -y
az monitor data-collection rule list -g rg-amp-lab -o table      # delete the portal-created DCR/DCE
# Everything:
az group delete -n rg-amp-lab -y ; ssh host01 'qm destroy 110 --purge' ; rm /etc/rsyslog.d/90-amp-lab.conf (both hosts)
```
