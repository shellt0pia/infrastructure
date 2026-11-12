# Observability

What watches the cluster and the devices around it: metrics, logs, dashboards and alerts. Deployed in stages ([bootstrap.md](bootstrap.md)), tracked in the [status](#status) below.

| Document | Content |
| --- | --- |
| [bootstrap.md](bootstrap.md) | First deployment: prerequisites, then the steps in order (stages 1 to 4 run, the noise pass of stage 4 two weeks later, stage 5 to do). |
| [evaluations.md](evaluations.md) | What was considered or rejected, what is still to verify, and the open points. |

The manifests are in `kubernetes/apps/observability` and `kubernetes/apps/observability-agents` ([Pod Security](#network-and-pod-security)):

| Folder | Content |
| --- | --- |
| `observability/victoria-metrics-k8s-stack` | `app/`: the release of the [stack](#the-release-of-the-stack) (the VictoriaMetrics operator and its CRDs, `VMSingle`, `VLSingle`, `VMAgent`, `VMAlert` and its internal `VMAuth`, `VMAlertmanager`, kube-state-metrics, node-exporter deployed in `observability-agents`, the data sources of Grafana, the default rules and dashboards, the mixins of the [alerting](#alerting)) and the ExternalSecret of the Alertmanager. `config/`: the second Flux Kustomization (`victoria-metrics-k8s-stack-config`), the etcd scrape and the LogsQL rules (`VMRule`). |
| `observability/grafana` | Grafana, its own release ([Grafana](#grafana)): the OIDC login, its ExternalSecret, its route, the `volsync` component for its volume, the community dashboards and the dashboards of this repository (`app/dashboards/`). |
| `observability/prometheus-operator-crds` | The CRDs of the Prometheus operator (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`), for the monitors that the other charts create. |
| `observability/vector-aggregator` | The Vector aggregator: the syslog of the devices (stage 3). |
| `observability-agents` | The namespace of the agents reading the nodes (`privileged`). node-exporter is deployed there by the release of the stack. |
| `observability-agents/vector-agent` | The Vector agent, on every node: the pod logs, the Hubble flows and the Talos logs of its node (stage 3). |

`prometheus-operator-crds` is also listed in `bootstrap/helmfile/crds.yaml.gotmpl`, so that the other applications can enable their monitors without `dependsOn` ([cluster](../cluster/README.md#overview)). Its CRDs are in the `templates/` of the chart: the helm-controller takes over those applied by `just bootstrap crds` (Flux leaves `install.disableTakeOwnership` to false), and `helm.sh/resource-policy: keep` keeps them if the release is ever uninstalled. The VictoriaMetrics CRDs come with the stack: the manifests of the repository that use them (etcd scrape, `VMRule`s) are in the second Kustomization, which depends on the release ([conventions](../conventions.md#flux-kustomizations)). The monitors of the other applications go next to them (the Flux controllers next to `flux-instance`, LINSTOR next to the `LinstorCluster`, Envoy Gateway next to its release), and so do their alert rules (`prometheusrule.yaml`, [alerting](#alerting)).

## Status

| Part | Tool | Status |
| --- | --- | --- |
| Metrics | `victoria-metrics-k8s-stack`: operator, `VMSingle`, `VMAgent`, kube-state-metrics, node-exporter | Deployed (stage 2) |
| Logs | `VLSingle` (from the stack), Vector agent and aggregator | Deployed (stage 3) |
| Dashboards | Grafana (its own release): the default dashboards of the stack, community dashboards pinned by revision, the dashboards of the repository | Deployed (stage 2) |
| Alerting | `VMAlert` and `VMAlertmanager` (from the stack), Pushover, dead man's switch to healthchecks.io | `VMAlertmanager` and Pushover deployed (stage 1). `VMAlert`, the default rules and the dead man's switch deployed (stage 4a). The rules of the repository, the mixins and the Piraeus rules deployed (stage 4b). The noise pass two weeks later |
| Flux alerts | Rules of `vmalert` on the metrics of the flux-operator (`flux_resource_info`) | Rules deployed with stage 4a. The events of the notification-controller (stage 1) removed |
| Cluster scrape targets | From the stack: kubelet, cAdvisor, API server, scheduler, controller-manager, kube-state-metrics, node-exporter. By hand: etcd (`VMNodeScrape`). Monitors of the charts: Cilium agent, Cilium operator and Hubble, CoreDNS, cert-manager, External Secrets, flux-operator, Spegel, Reloader, external-dns, k8s-gateway, VolSync. Next to the applications: the Flux controllers (`PodMonitor`), Piraeus (LINSTOR controller, satellites and drbd-reactor, affinity controller), Envoy Gateway (controller and proxies). The Vector agent and aggregator (`podMonitor` of their chart) | Deployed (stage 2). Vector deployed (stage 3) |
| Talos logs, Hubble flows | Vector, `machine.logging`, `KmsgLogConfig`, `hubble.export` | Hubble export in place. Talos destinations applied on both nodes, to the agent of the node (stage 3) |
| External devices | snmp_exporter, Graphite, syslog, blackbox_exporter | Decided, [to verify](evaluations.md#to-verify) per device |

## Overview

```mermaid
flowchart TD
    subgraph SRC["Sources"]
        CLU["Cluster: monitors, kube-state-metrics, node-exporter, control plane"]
        DEV["Devices: OPNsense, MikroTik, Wi-Fi AP, NAS"]
        EXT["Uptime Kuma, Pocket ID (PikaPods)"]
        LOGS["Pod logs, Hubble flows"]
        TAL["Talos service and kernel logs"]
    end
    CLU -->|scrape| VA["VMAgent, 2 replicas"]
    DEV -->|"SNMP exporter, Graphite push"| VA
    EXT -->|"blackbox exporter"| VA
    VA -->|remote write| VM[("VMSingle")]
    LOGS --> VAG["Vector agent, DaemonSet"]
    VAG --> VL[("VLSingle")]
    TAL -->|"TCP, json_lines"| VAGG["Vector aggregator, 2 replicas"]
    DEV -->|syslog| VAGG
    VAGG --> VL
    VM --> RULES["VMAlert, 2 replicas"]
    RULES --> AM["VMAlertmanager, 2 replicas"]
    AM -->|Pushover| PO["Phone"]
    AM -->|"dead man's switch"| HC["healthchecks.io"]
    VM --> GR["Grafana"]
    VL --> GR
```

## Objectives

- Metrics and logs of the cluster (Kubernetes, Cilium, Flux, LINSTOR and DRBD, certificates, VolSync), of the Talos nodes, and of the devices: OPNsense, the MikroTik switch, the Grandstream access point, the NAS.
- HTTP checks of Uptime Kuma and Pocket ID, which stay hosted at PikaPods. Uptime Kuma is already an independent observer from the outside: it stays that, the cluster does not replace it.
- The logs needed to enforce the network policies: the audited and denied flows searchable by namespace ([cluster](../cluster/README.md#network-policies)).
- Dashboards in Git, a single notification channel: everything goes through Alertmanager to Pushover.
- Resilience to the loss of one of the three nodes, for the monitoring as well: [level 1](#high-availability) below. Without kube-02 it cannot be tested ([nodes](../nodes/README.md#test-phase-2-nodes)).

Resources are not a constraint: the current hosts use a fraction of their RAM, and the heavy workloads (Plex transcoding, Immich) run on the GPU. Each node has 16 GiB and a 1 TB NVMe shared elastically by Piraeus between `local` and `replicated`. The sizes are in [storage and retention](#storage-and-retention).

## Decisions

### Stack

| Need | Tool | Why |
| --- | --- | --- |
| Metrics storage and scraping | `VMSingle` and `VMAgent` of the VictoriaMetrics operator | Frugal, single binary, reads the `ServiceMonitor`, `PodMonitor` and `PrometheusRule` objects (the operator converts them), natively ingests Graphite |
| Logs storage | `VLSingle` (VictoriaLogs, single node) | Same family, frugal, queried from Grafana |
| Logs collection and reception | Vector, for everything | One tool and one configuration language for pod logs, Hubble files, Talos and device syslog ([why not vlagent](evaluations.md#vector-or-vlagent)) |
| Dashboards | Grafana, provisioned from Git | No `vmui`: Grafana is the only UI |
| Alerts | `VMAlert` and `VMAlertmanager` | The only notification path, Pushover as the only channel |
| Packaging | `victoria-metrics-k8s-stack`, one release, the components not needed disabled, Grafana apart | Fewer charts to follow: the operator, its resources, the scrapes of the control plane, the rules and the dashboards stay consistent with each other (the `job` labels the rules expect). [Why not separate releases](evaluations.md#victoria-metrics-k8s-stack-or-separate-releases) |

Outside the stack: Grafana (its own release, [why](evaluations.md#grafana-apart-from-the-stack)) and Vector (two releases, agent and aggregator).

### The release of the stack

- **Enabled:** the operator, `vmsingle`, `vlsingle`, `vmagent`, `vmalert` (and the internal `vmauth` the chart creates for it), `alertmanager`, `kube-state-metrics`, `prometheus-node-exporter` (`namespaceOverride: observability-agents`), the scrapes of the kubelet (and cAdvisor), the API server, the scheduler and the controller-manager, the default rules and dashboards.
- **Disabled:** `grafana` (its own release), the cluster modes and the traces (`vmcluster`, `vlcluster`, `vtsingle`...), `vlagent`, the public `vmauth`, every ingress, `kubeProxy` (Cilium replaces kube-proxy), `kubeDns` and `coreDns` (the CoreDNS chart has its own monitor), `kubeEtcd` (see below).
- **`vmalert`:** two replicas spread over the nodes, evaluating every 30 s (the scrape interval) every `VMRule` of the cluster, the `PrometheusRule`s converted by the operator included (`selectAllByDefault`). The chart wires the rest: `remoteWrite` to `VMSingle` (the `ALERTS` series and the state of the `for`), `remoteRead` from it (that state restored at a restart, so a restart neither resolves nor delays an alert), a notifier per Alertmanager replica. Its datasource is the internal `VMAuth` of the chart (two replicas): `/select/logsql/` to `VLSingle` for the LogsQL rules, the rest to `VMSingle`; if it is down, `Watchdog` stops too and the dead man's switch notices. The links of the alerts (`generatorURL`) open an *Explore* of their expression in Grafana (`external.grafana.host`). `VMSingle` and `VLSingle` proxy the rules API of `vmalert` (`vmalert.proxyURL`, set by the chart): its rules show in *Alerting → Alert rules* of Grafana, under each data source.
- **For Grafana:** with its subchart disabled, the stack still creates the ConfigMap of the data sources (`grafana.forceDeployDatasource: true`, `victoria-metrics-k8s-stack-grafana-ds`) and the Job creates those of the default dashboards, with the labels that the sidecars of the Grafana release read (`grafana_datasource: "1"`, `grafana_dashboard: "1"`). Checked on the render: `VMSingle` (type `prometheus`, uid `VictoriaMetrics`, the default) and the Alertmanager. A data source of a plugin type (VictoriaLogs) is only rendered when `grafana.plugins` of the values of the stack lists it: set at stage 3, checked on the render (uid `VictoriaLogs`).
- **etcd:** Talos runs it outside any pod, and the chart only finds it through a Service selector or a list of IPs. A `VMNodeScrape` on the control plane nodes instead (`node-role.kubernetes.io/control-plane`, port 2381, no address in Git), with the label `job="kube-etcd"` (the rules and the dashboard select `job=~".*etcd.*"`). The etcd rules and dashboard follow `kubeEtcd.enabled` in the chart: their sources are enabled explicitly.
- **Scheduler and controller-manager:** the chart scrapes them through headless Services in `kube-system` that select the Talos static pods by `component: kube-scheduler` and `component: kube-controller-manager` (the default selectors of the chart, labels checked on the cluster), not a list of IPs (ports 10259 and 10257, already bound to `0.0.0.0`). Their certificates are self-signed (Talos sets no `--tls-cert-file`): `insecureSkipVerify`.
- **node-exporter** in `observability-agents` (`namespaceOverride`); its `VMServiceScrape` stays in `observability` with a `namespaceSelector` on `observability-agents`.
- **The `cluster` label:** `VMAgent` adds `cluster: kube-cluster01` to every series (`externalLabels`), for the `cluster` variables of the community dashboards and the `clusterLabel` of the rules.
- **CRDs:** shipped in the chart (`crds/`), so the HelmRelease sets `upgrade.crds: CreateReplace` for them to follow the chart. `crds.cleanup.enabled: false`: its hook would delete the CRDs, and every VictoriaMetrics resource with them, when the release is uninstalled.
- **Images:** no tag in the values, the versions follow the chart (`global.versions`).
- **Rules and dashboards:** the chart downloads them with a Job (Helm hook `post-install,post-upgrade`, `restricted` security context and an `emptyDir` on `/tmp` set in the values) and creates the `VMRule`s and the dashboard ConfigMaps itself, outside Helm and Flux (owner references, pruned when they leave the configuration). Its sources are the `main` or `master` branches upstream, not pinned: the content only changes with an upgrade of the chart ([why](evaluations.md#sources-of-the-rules-and-dashboards)). The default rules are enabled with `vmalert` (stage 4a): before, the dashboards of kube-prometheus that read their recording rules stayed empty.
- **Default rules disabled:** `KubeCPUOvercommit` and `KubeMemoryOvercommit` until kube-02 joins: with two nodes, losing one never leaves room for the requests.
- **Mixins:** the sync-job also fetches the alert rules of cert-manager, CoreDNS and Cilium (`defaultRules.sources`, [alerting](#alerting)), with the same overrides as the default rules (`defaultRules.rules`, `defaultRules.groups`).
- **kube-state-metrics** also exports the `ReplicationSource`s of VolSync (`customResourceState`, with `rbac.extraRules` to list them): `kube_volsync_replicationsource_created`, `_status_last_sync_time` (0 before the first sync) and `_spec_paused`, the dates as Unix timestamps, labelled with the `namespace` and `name` of the object. The rules that read them stay next to VolSync. And the message of the `Ready` condition of the Flux objects, which `flux_resource_info` does not carry: `kube_flux_resource_ready_message` (`namespace`, `name`, `customresource_kind`, `message`), every kind of the groups `kustomize.toolkit.fluxcd.io/v1`, `helm.toolkit.fluxcd.io/v2` and `source.toolkit.fluxcd.io/v1` (`kind: "*"`), and the `FluxInstance` (`fluxcd.controlplane.io/v1`), with read-only RBAC on them. Not the `FluxReport`: its message changes at each report (`Reporting finished in 123ms`, every 30 s), a new series each time; nor the `ResourceSet`s, which `FluxResourceNotReady` does not read (to add to both if they are adopted). The message changes with each revision (`Applied revision: …`): about 70 new series per commit (the Kustomizations and their `GitRepository`), the old ones stale at once, plus the upgrades, the new chart versions, the indexes of the `HelmRepository`s and the reconciliations of the `FluxInstance` (about a hundred a day). Negligible next to the active series; dropping the message of the `Ready` objects (relabeling on the scrape of kube-state-metrics) would mean redefining the endpoints of its `VMServiceScrape`.
- **Rules of the repository:** next to each application, see the [alerting](#alerting). The VictoriaMetrics, VictoriaLogs, operator and Alertmanager rules come with the stack.
- **Dashboards:**
  - The default ones of the stack: Kubernetes views, node-exporter, VictoriaMetrics, VictoriaLogs, operator, etcd, control plane.
  - Those of the Cilium chart, which follow its version: agent, operator, and Hubble (metrics, network overview, DNS and L7 HTTP). The Hubble ones mostly read flow metrics that are not enabled, only their `drop` panels can show data: to decide ([open points](evaluations.md#open-points)). The chart creates them in `observability` (`dashboards.namespace` in the values of Cilium), so the bootstrap creates that namespace before installing Cilium ([cluster](../cluster/README.md#overview)). Their `DS_PROMETHEUS` variable picks the default Prometheus data source, `VMSingle`. The ones on grafana.com (16611, 16612, 16613) date from Cilium 1.12.
  - Community dashboards by `gnetId` and `revision` in the values of the Grafana release, pinned, in the *Community* folder: cert-manager (20842), External Secrets (21640), external-dns (15038), LINSTOR and DRBD (15917), Envoy Gateway (24460) and the Envoy proxies (24459). Flux has none up to date on grafana.com: the *Flux Control Plane* dashboard of `fluxcd/flux2-monitoring-example`, by a URL pinned to a commit. Their inputs (`DS_METRICS`...) are replaced by the data source of the stack.
  - The dashboards of the repository (the denied flows, `app/dashboards/denied-flows.json`) as JSON in Git, next to the Grafana release, a ConfigMap generated by kustomize and read by its sidecar, with `kustomize.toolkit.fluxcd.io/substitute: disabled`: the Kustomization of Grafana substitutes the variables of the `volsync` component, and Grafana uses `${...}` variables too.
- **Upgrades:** the chart is in 0.x, its minors may break: read its changelog before each upgrade, no automerge by Renovate ([roadmap](../roadmap.md#upgrades)).

### High availability

Level 1: the loss of a node costs a few minutes of access, never data.

- `VMSingle` and `VLSingle` run as one pod each, on `replicated` volumes: the Piraeus failover reschedules them on another node ([storage](../storage/README.md#decisions)). While they are down, the collectors buffer.
- No gap in metrics and logs: `VMAgent` runs two replicas that both scrape every target, `VMSingle` deduplicates (`-dedup.minScrapeInterval=30s`, the scrape interval). Vector buffers on disk towards VictoriaLogs.
- The alert path is redundant by design, since a dead monitoring must still ring: `VMAlert` with two replicas, `VMAlertmanager` with two replicas (gossip between them), and a dead man's switch.
- Grafana: one replica with the same failover. Its configuration is in Git, its small state (SQLite) goes through the `volsync` component. Two replicas would need session affinity because of the local SQLite.
- No S3 storage for this: B2 covers `vmbackup` if the metrics are ever backed up ([backups](../backups/README.md#what-is-backed-up)). If an S3 service is ever needed, [Garage](evaluations.md#s3-storage) is the candidate.
- UDP syslog is lost while the receiver is down: TCP wherever the device supports it, and always for Talos.

### Storage and retention

| Data | Volume | Retention |
| --- | --- | --- |
| `VMSingle` | 50 Gi, `replicated` | 90 days (`retentionPeriod: 90d`), scrape interval 30 s |
| `VLSingle` | 30 Gi, `replicated` | 30 days, and `-retention.maxDiskSpaceUsageBytes` at about 25 Gi as a safety net |
| `VMAlertmanager` | A small `local` volume per replica | The silences, copied between the replicas by the gossip |
| Vector aggregator | A `local` volume per replica (StatefulSet) | Disk buffer |
| Vector agent | `hostPath` `/var/lib/vector` | Disk buffer, `max_size` about 1.25 Gi per node |
| Grafana | The `volsync` component, `replicated` | Backed up to B2 |

Sizes estimated, to check in the dashboards of VictoriaMetrics and VictoriaLogs after two weeks. The volumes can be expanded later, the retentions changed at any time.

Every component has modest requests and a memory limit from the start, with a comment saying they are to resize from the metrics ([roadmap](../roadmap.md#cluster-tools)). Exception: the memory limits of Vector (1 Gi for the agent, 512 Mi for the aggregator) are sized for the catch-up, not for the idle use ([memory of Vector](evaluations.md#memory-of-vector)).

### Alerting

- **Severities:** `critical` to Pushover with priority 1, `warning` with priority 0, `info` to a null receiver (visible in Grafana only). A noise-tuning pass after two weeks of alerts.
- **Grouping:** `group_by: [alertname, namespace]`, `repeat_interval: 12h`. No quiet hours: the do-not-disturb mode of the phone covers the nights.
- **Alerts to every replica:** the Alertmanager replicas share the silences and the notifications already sent (gossip), not the alerts. `vmalert` sends each alert to both (a notifier per replica), and each `vmalert` replica sends its own: one notification in the end. An alert posted by hand goes to both pods too ([bootstrap](bootstrap.md#4-alert-rules-and-the-dead-mans-switch)); through the Service, it reaches one replica, and Grafana, which reads the other one, may not show it.
- **Template:** one for both Pushover receivers. The title: the status, the number of firing alerts, the name and the namespace (`[FIRING:1] Test (debug)`). The body: one line per alert, its `summary`, else its `description`, else `(no details)`, prefixed `[resolved]` once resolved. The link (*Grafana*): *Alerting → Active notifications* on the `Alertmanager` data source, filtered on the name and namespace of the group, from where *See source* opens the `generatorURL` (an *Explore* of the expression) and *Silence* silences it. Not the `generatorURL` itself: often over the 512 characters of a Pushover URL.
- **Configuration in Git, secrets as files:** the routes and receivers are in the values of the stack. The Pushover user key and token, and the ping URL of healthchecks.io, come from ExternalSecrets mounted in the pods (`spec.secrets` of the `VMAlertmanager`) and read through `user_key_file`, `token_file` and `url_file`.
- **Pushover:** an application token from the `pushover-alertmanager` item (`username`: the user key, `credential`: the token; one token per tool, [conventions](../conventions.md#secrets)).
- **Flux alerts from the metrics of the flux-operator**, not from the events of the notification-controller ([why](evaluations.md#rejected-and-alternative-options)). The operator exports `flux_resource_info` (every Flux object of the cluster: `kind`, `name`, the namespace of the object in `exported_namespace`, `ready`, `reason`, `suspended`) and `flux_instance_info`, rebuilt at each of its reports (`reporting.interval: 30s`, 5 minutes by default). The rules, `kubernetes/apps/flux-system/flux-operator/app/prometheusrule.yaml`: `FluxResourceNotReady` (`warning`, 10 minutes: `Ready` False, not suspended, not `DependencyNotReady`, the definition of "failing" of the operator itself; the reason and the message of the `Ready` condition (from kube-state-metrics, [above](#the-release-of-the-stack)) read back in the summary by queries, out of the labels so that a change does not restart the `for`), `FluxResourceSuspended` (`info`, a day) and `FluxMetricsAbsent` (`warning`, 15 minutes: without the metric, the first rule is blind). The full error otherwise: `flux get` or the web UI of the flux-operator. A long message (the health checks of a Kustomization) can fill the 1024 characters of a Pushover message, which the Alertmanager truncates.
- **Inhibition:** a `critical` alert silences the `warning` of the same `alertname` (the two thresholds of a rule, as in kube-prometheus), when the labels of the `equal` list match: `namespace`, and the labels that tell apart the instances of an alert whose namespace is the one of its exporter, `instance`, `mountpoint`, `persistentvolumeclaim`, `exported_namespace`, `name`, `node`, `storage_pool`. Without them, a `critical` on one disk or certificate would hide the `warning`s of all the others. A label missing on both sides counts as equal, so each one added can only narrow the inhibition. To recheck at each new source of rules: the pairs of severities and their labels ([bootstrap](bootstrap.md#4-alert-rules-and-the-dead-mans-switch)).
- **`InfoInhibitor`** (`severity: none`, default rules): fires as long as an `info` alert fires in a namespace, to inhibit them in a setup that notifies them. Ours never does: its own route to `"null"`, without which the default receiver would notify it.
- **Dead man's switch:** the `Watchdog` alert of the default rules (always firing) has its own route (`group_interval: 30s`, `repeat_interval: 1m`) to a webhook receiver, the ping URL of a healthchecks.io check (field `kube-cluster01-alertmanager` of the `healthchecks` item). The check expects a ping every minute, with a grace of 3 minutes, and notifies through healthchecks.io itself. The healthchecks checks of the backups may then be dropped ([backups](../backups/README.md#monitoring)).
- **Rules of the repository**, next to each application: a `prometheusrule.yaml` (converted to a `VMRule` by the operator), in the `kustomization.yaml` of its folder. Each rule has a `summary` (the line of the notification) and a `description`. A rule whose series carry no namespace of their own gets one by `label_replace`, for the grouping and the inhibition.

  | Folder | Alerts |
  | --- | --- |
  | `cert-manager/cert-manager/app` | `CertManagerCertExpirySoon` `critical`, under 7 days (1 hour) |
  | `backups/volsync/app` | `VolSyncVolumeOutOfSync` (1 hour), `VolSyncMissedIntervals` (over a day), `VolSyncBackupLate` (no sync for 26 hours, from kube-state-metrics), `VolSyncBackupPaused` (`info`, 1 hour); `namespace` from `obj_namespace` ([backups](../backups/README.md#monitoring)) |
  | `flux-system/flux-operator/app` | The Flux alerts (above) |
  | `kube-system/cilium/app` | `NetworkPolicyAuditedFlows` (`info`, any audited flow over the last hour, without `for`: the rare ones too), `NetworkPolicyDroppedFlows` (`warning`, dropped for 10 minutes); `namespace` from the side whose policy decides |
  | `observability-agents/vector-agent/app`, `observability/vector-aggregator/app` | The same rules on the `job` of each: `VectorComponentErrors` and `VectorDiscardedEvents` (over 15 minutes, `increase_pure`: Vector creates the counters at the first event), `VectorSinkStalled` (a sink receiving events and sending none for 15 minutes: an unreachable destination, which Vector retries without limit and without a component error), `VectorBufferFillingUp` (a disk buffer over 80 % for 10 minutes) |
  | `piraeus-datastore/piraeus-operator/cluster` | `linstorStoragePoolAtCapacity` `critical`, under 10 % free |
  | `observability/victoria-metrics-k8s-stack/config` | `SELinuxUnlabeledDenials` (LogsQL, below) |

- **Upstream rules, followed rather than written** where the project publishes them:
  - **Mixins**, fetched by the sync-job of the stack (`defaultRules.sources`, from `monitoring-mixins/website`, `master`, unpinned like the default rules): cert-manager (`CertManagerAbsent`, `CertManagerCertExpirySoon` `warning`, `CertManagerCertNotReady` `critical`, `CertManagerHittingRateLimits`), CoreDNS (its `job="kube-dns"` rewritten to the regexp `coredns-metrics|k8s-gateway-metrics`, the cluster DNS and k8s-gateway; `CoreDNSDown` then only fires when both are absent) and Cilium (the mixin of Isovalent, on the metrics of the open-source agent and operator). Disabled in the values: the Cilium groups not used here (`IPAM`, `Clustermesh`, `Kvstoremesh`), `Cilium Drops` (its only rule duplicates `NetworkPolicyDroppedFlows`, without namespaces), and `RunningOutOfCiliumClusterIdentities` (its template fails when the alert is rendered).
  - **Piraeus:** `config/extras/monitoring/alerts.yaml` of the operator repository (`linstor.rules`, `drbd.rules`), applied unmodified as the `PrometheusRule` `piraeus-datastore`. The `GitRepository` `piraeus-operator` (next to the release, at the tag of the chart, `ignore` keeping that file only) and the Flux Kustomization `piraeus-alerts` (depends on `piraeus-operator`, which creates the source). Renovate updates the chart and the tag in one PR (package rule `Piraeus`); the patches of Piraeus are automerged, the rules follow without review. A noisy rule of that file is silenced by an Alertmanager route to `"null"` on its name, the file staying unmodified.
  - **A `critical` on top of an upstream `warning`** (`CertManagerCertExpirySoon`, `linstorStoragePoolAtCapacity`): the same name and the same labels, so that the inhibition silences the `warning` while the `critical` fires.
  - **Checked before a change:** the render of the sync-job and `vmalert -dryRun`. `-dryRun` parses the templates but does not execute them: a template that fails at rendering only shows when the alert fires ([evaluations](evaluations.md#open-points)).
- **LogsQL rules:** `VMRule`s (a `PrometheusRule` has no group `type`) in `config/` of the stack, groups `type: vlogs`, evaluated through the internal `VMAuth`; `vmalert` limits each query to the interval of its group. `SELinuxUnlabeledDenials` (`warning`, every 5 minutes): the SELinux denials on `unlabeled_t` files per node, a volume mounted without its context ([storage](../storage/README.md#decisions)). Their link is an *Explore* on the default data source, not VictoriaLogs ([open points](evaluations.md#open-points)).
- **Tests of a rule:** its syntax (`vmalert -dryRun`, on the rules of the repository and on the `VMRule`s the sync-job renders locally), then its expression run against `VMSingle` or VictoriaLogs before the commit (a rule on a series that does not exist never fires: names and labels from the cluster), then the failure provoked by hand when cheap, each test written in [bootstrap.md](bootstrap.md#4-alert-rules-and-the-dead-mans-switch). The test resources are applied by hand, never in Git. No unit tests (`vmalert-tool`) unless an expression becomes non-trivial.
- **The denied flows:** the policy verdicts of Hubble (`hubble_policy_verdicts_total`), `action="audit"` while the policies are in audit mode, `action="dropped"` once enforced, both namespaces in the labels. `hubble_drop_total` is not alerted: it has no namespace, and its policy drops are already in the verdicts; its other drops (today only ICMPv6 `INVALID_SOURCE_IP`) are watched apart ([roadmap](../roadmap.md#to-check-or-watch)).
- **Not alerted:** the metadata of the LINSTOR thin pool, not exported ([open points](evaluations.md#open-points)).

### Logs

- **Vector agent** (DaemonSet, `observability-agents`): the pod logs (`/var/log/pods`, `kubernetes_logs` source), the Hubble export (`/var/run/cilium/hubble/events*.log`, JSON lines on each node, in tmpfs) and the Talos logs of its node (hostPorts 6050 and 6051 on `127.0.0.1`, below). Root without any capability (the files belong to root), read-only root filesystem and node paths. The checkpoints and the disk buffers (512 MiB for the pods and for Hubble, 256 MiB for Talos) in `hostPath` `/var/lib/vector`. The pod labels are kept, not the pod annotations nor the labels of the namespace and the node (too heavy on every line).
- **Vector aggregator** (StatefulSet, two replicas, `observability`): the syslog of the devices. A LoadBalancer Service on the [pinned addresses](../reference.md#pinned-loadbalancer-addresses) `192.168.19.2` and `fd38:4c4d:8f66:13::2`, named `syslog.kube-cluster01.shelltopia.net`, port 514 (TCP and UDP, RFC 5424 and RFC 3164) to the pod port 5514. Disk buffer (1 GiB) on a `local` volume of 2 Gi per replica. `restricted`, UID 65534: the pods only listen above 1024.

- **Syslog on 514 only.** Syslog over TCP (RFC 6587) has no port of its own: 514 is the usage. 601 is the port of RFC 3195 (BEEP), which syslog-ng reuses for its `syslog()` driver: no device here needs it. No TLS (6514) for now ([open points](evaluations.md#open-points)).
- **`externalTrafficPolicy: Local`** keeps the source address of the devices (`source_ip`): only the nodes running a replica announce the addresses over BGP.
- **Talos** sends its logs over raw TCP in `json_lines` (`talos/patches/logging.yaml.j2`; Talos v1.14.4, same behaviour as in the v1.12 documentation) to the Vector agent of its node: the service logs (`machine.logging.destinations`) to `127.0.0.1:6051`, the kernel logs (`KmsgLogConfig`) to `127.0.0.1:6050`, hostPorts of the agent that Cilium connects from the host to the pod. IPv4 only, the exception to dual stack: Cilium maps a loopback hostPort to one family, and Helm cannot keep two `hostIP`s on one container port ([evaluations](evaluations.md#to-verify)). Kernel logs only need `KmsgLogConfig` on a running node, the kernel argument is for the early boot. Nothing is sent before the agent runs (cluster bootstrap): `talosctl logs` and `talosctl dmesg` stay the reference then.
- **The node of the Talos logs** is the node of the agent (`VECTOR_SELF_NODE_NAME`). Sending them to the aggregator did not name the node of the kernel logs: `KmsgLogConfig` takes no tag, and for the node running the replica the peer address was its `cilium_host` address, without PTR ([evaluations](evaluations.md#to-verify)).
- **Fields** common to every source:
  - `log_source`: `pods`, `hubble`, `talos-service`, `talos-kernel` or `syslog`, the first stream field everywhere (`log_source:hubble` in a query);
  - `node`: the Kubernetes name of the node, every source except syslog (the device sets `host`, the aggregator adds `source_ip`: it listens on `[::]`, so IPv4 peers show up as `::ffff:a.b.c.d`, a prefix it strips).
- **Stream fields:** the pods by namespace, pod and container; Hubble by node; Talos by node and `talos-service`; the syslog by `host`.
- **Hubble flows:** the JSON of the flow is merged at the root (`flow.verdict`, `flow.source.namespace`, `flow.drop_reason_desc`...), with a short message: `VERDICT DIRECTION namespace/pod -> namespace/pod DROP_REASON Summary` (the IP when there is no pod).
- **Sinks:** the Elasticsearch API of VictoriaLogs (`/insert/elasticsearch/`, `_msg_field`, `_time_field` and `_stream_fields` as parameters), disk buffers that block the sources when full. No `dependsOn` on VictoriaLogs: the buffers cover its absence. Batches of 1 MiB (`batch.max_bytes`) instead of 10 MiB by default: during a catch-up (a backlog of pod logs, the disk buffers after an outage), the batches fill at once and the default ones led the agent to an OOM kill at 256 Mi ([memory of Vector](evaluations.md#memory-of-vector)).
- At stage 5, Vector enriches and filters per device (for instance the pf noise of OPNsense) before VictoriaLogs.

### Metrics

- `VMAgent` scrapes every 30 s the monitors of the charts ([status](#status)), kube-state-metrics, node-exporter, the kubelet and cAdvisor, the API server and the control plane (etcd `:2381`, scheduler, controller-manager, already exposed by Talos). It selects the monitors of every namespace (`selectAllByDefault`), the `ServiceMonitor` and `PodMonitor` objects converted by the operator.
- **The operator only looks for the Prometheus CRDs at its start:** when the `monitoring.coreos.com` API is missing then, it disables the conversion of the `ServiceMonitor`, `PodMonitor`, `PrometheusRule` and `Probe` objects until its next restart (its log says `controller disabled either by provided flag or respective CRD is not found`). The CRDs are applied by `just bootstrap crds` before the applications, and the Kustomization of the stack depends on `prometheus-operator-crds`. If the CRDs ever arrive after the operator (no converted `VMServiceScrape` outside of the stack, only its own targets): `kubectl -n observability rollout restart deploy victoria-metrics-k8s-stack-victoria-metrics-operator`.
- The Hubble metrics (`drop`, `policy`) are enabled with the workload contexts, for the dashboard and the alert of the denied flows. At each end: the namespace (`source_namespace`, `destination_namespace`, from `labelsContext`), and in `source` or `destination` the workload, else the `app` label (Hubble only knows the workload of the pods of its own node), else the reserved identity (`reserved:world`, `reserved:host`...): `sourceContext` and `destinationContext` set to `workload-name|app|reserved-identity`. `hubble_drop_total` adds `reason` and `protocol`, `hubble_policy_verdicts_total` adds `direction`, `match` and `action` (`forwarded`, `dropped`, `audit`, `redirected`).
- VolSync checks the caller of its metrics endpoint (HTTPS, a TokenReview): a post-renderer of its release adds the ServiceAccount token of `VMAgent` to its ServiceMonitor.
- Graphite: `VMAgent` listens for it (`-graphiteListenAddr`) behind a LoadBalancer Service on the [pinned addresses](../reference.md#pinned-loadbalancer-addresses) `192.168.19.3` and `fd38:4c4d:8f66:13::3`, named `graphite.kube-cluster01.shelltopia.net`. The TrueNAS exporter only takes an IP: the name is reserved for the devices that take one.
- The data sources of Grafana are generated by the stack (ConfigMaps read by the sidecar of Grafana): `VMSingle` (Prometheus type), VictoriaLogs (plugin `victoriametrics-logs-datasource`), the Alertmanager.

### Grafana

- **Its own release** (`grafana` chart of `grafana-community/helm-charts`), in `observability`, apart from the stack ([why](evaluations.md#grafana-apart-from-the-stack)). Its sidecars read the data sources and dashboards that the stack generates in the namespace, through a Role of the repository limited to the ConfigMaps (the Role of the chart also reads the Secrets). Its volume is the PVC of the `volsync` component (`APP: grafana`, owned by its UID 472), mounted as `existingClaim`, hence the `Recreate` strategy. The `initChownData` container is disabled (it runs as root, which `restricted` refuses).
- **No admin API, so no reload by the sidecars:** without a local account, the sidecars cannot call the reload API of Grafana. The dashboards are files that Grafana rescans by itself. The data sources are written by an init container at startup (in `LIST` mode: the chart passes `sidecar.datasources.watchMethod` to it as is, and the default `WATCH` never exits, leaving the pod stuck in `Init`): Reloader restarts Grafana when their ConfigMap changes (an upgrade of the stack, VictoriaLogs at stage 3), through `configmap.reloader.stakater.com/reload: victoria-metrics-k8s-stack-grafana-ds` next to `reloader.stakater.com/auto` (no pod references that ConfigMap, the sidecars read it through the API). Reloader checks the named list before `auto`, the two combine. Creating an admin account only for this reload was rejected ([evaluations](evaluations.md#rejected-and-alternative-options)).
- **The community dashboards are downloaded at each start** (an init container, from grafana.com and GitHub): if grafana.com is down, Grafana does not start until it is back.
- **Login by OIDC only, with the Pocket ID, from the first start**: no local account, no password. `disable_initial_admin_creation` (only effective on an empty database, hence from the first start; set as the `GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION` variable, so that the chart creates no admin Secret), `[auth] disable_login_form = true`, and the generic OAuth integration with PKCE and `auto_login`, scopes `openid profile email groups`. Endpoints: `https://id.shelltopia.org/authorize`, `/api/oidc/token`, `/api/oidc/userinfo`.
- **Roles from the groups** of the `groups` claim: `grafana_admins` is `GrafanaAdmin` (`allow_assign_grafana_admin`), `grafana_viewers` is `Viewer`. `allowed_groups` lists both and `role_attribute_strict = true` refuses a user with no valid role. `allow_sign_up` creates the user at the first login, the groups being the only gate.
- **The client**: a confidential OIDC client in the Pocket ID, callback `https://grafana.shelltopia.org/login/generic_oauth` (and `root_url` set accordingly), the id and the secret in the `pocket-id-grafana` item (`kubernetes` vault: `username` and `credential`, [naming](../secrets/README.md#naming-of-the-items)), injected by the ExternalSecret `grafana-oidc` as the `GF_AUTH_GENERIC_OAUTH_CLIENT_ID` and `_SECRET` variables (Reloader restarts Grafana when they change).
- **Pocket ID down** (it is hosted at PikaPods): no new login, nothing else. The alerts do not go through Grafana, the dashboards are in Git. `use_refresh_token` stays off, so that an outage does not end the open sessions.
- **No break-glass account, by design.** Grafana holds nothing that Git does not: the way back is a new empty database with `disable_initial_admin_creation = false` and the login form, both in Git. The metrics and logs stay reachable with `kubectl port-forward` on the APIs of `VMSingle` and VictoriaLogs. To verify at the first deployment.
- Only on the `internal` Gateway, as `grafana.shelltopia.org` ([conventions](../conventions.md#routes-and-names)). The other UIs of the cluster use the same Pocket ID ([roadmap](../roadmap.md#cluster-tools)).

### External devices

| Device | Metrics | Logs |
| --- | --- | --- |
| OPNsense | `os-node_exporter` plugin | Remote syslog |
| MikroTik CRS326 (RouterOS 7) | `snmp_exporter` | Remote syslog (BSD syslog or CEF, UDP, TCP or TLS, the address is an IP or text) |
| Grandstream GWN7664 | `snmp_exporter` (SNMP v2/v3) | Syslog |
| TrueNAS CE 25.10 | Graphite exporter of *Reporting* (pushed), received by `VMAgent` | Remote syslog |
| Uptime Kuma, Pocket ID | `blackbox_exporter` (HTTP probes) | None |

Each line has points to [verify](evaluations.md#to-verify) before it is relied on. Every device is in a separate VLAN, except that the NAS also has a leg in the nodes subnet: its traffic to the cluster comes from its main interface ([network](../network/README.md#nas-no-asymmetric-path)).

### Network and Pod Security

- **Receivers** (Vector aggregator, Graphite of `VMAgent`): one LoadBalancer Service each, on their own addresses pinned in the `internal` pool, IPv4 and IPv6, like every LoadBalancer address ([conventions](../conventions.md#loadbalancer-addresses)). Their names, in `shelltopia.net`, are static `A` and `AAAA` host overrides in Unbound, created by hand and kept in sync with the addresses ([dns](../dns/runbook.md#where-to-create-a-record)). Ingress from `world` is enough for the devices: OPNsense filters the VLANs, and the baseline policy of the namespace keeps any other pod out. Talos reaches the agent of its node from `host`, allowed by the baseline.
- **Scraping:** `VMAgent` reaches every pod (an exception in `kubernetes/apps/kube-system/cilium/policies/baseline.yaml`) and the node ports it scrapes (`host.yaml`: kubelet 10250, etcd 2381, scheduler 10259, controller-manager 10257, node-exporter 9100, the Cilium agent 9962 and operator 9963, Hubble 9965, drbd-reactor 9942).
- **Other flows:** the Vector agent (`observability-agents`) to VictoriaLogs. The rest stays inside `observability`.
- **Scrapers** (`snmp_exporter`, `blackbox_exporter`): egress by FQDN (`toFQDNs`), never by address, as the [conventions](../conventions.md#network-policies) ask for every pod reaching the internal network.
- **Pod Security:** `observability-agents` is `privileged`, for the Vector agent (`hostPath`: the pod logs, the Hubble files, its buffer; `hostPort` for Talos) and node-exporter (`hostNetwork`, `hostPID`, `hostPath`). `observability` is `restricted`: the values set the security context where a chart default does not meet it (the operator, the Alertmanager, the Job of the rules and dashboards, Grafana). For the resources of the operator, `useStrictSecurity` is not enough: any `securityContext` in the spec replaces its defaults, and the chart sets a partial one as soon as there is a volume, so the values write it out in full.
- **Secrets**: ExternalSecrets from the `kubernetes` vault, one item per tool or device, named `<provider>-<app>` or `<host>-<service>` (`pushover-alertmanager`, `pocket-id-grafana`, `sw-01-snmp`, `ap-01-snmp`, the ping URL in `healthchecks`).
