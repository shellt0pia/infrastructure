# Observability: first deployment

Deploying the observability stack on the cluster, in five stages, each one useful without the next. Architecture: [README.md](README.md). Nothing below was run yet (*Not tested yet*): the commands and the checks are to adjust to the names of the real resources, and the checkboxes track `kube-cluster01`.

Create every prerequisite of a stage before starting it, then follow the stages in order. The order was chosen so that the alerts come first (they also carry the Flux notifications), the network policies are enforced as early as the logs allow, and the external devices come last. Each stage is one push, checked before the next one.

The release `victoria-metrics-k8s-stack` is deployed at stage 1 with only the operator and the Alertmanager; each later stage enables more of its components in the values ([the release](README.md#the-release-of-the-stack)).

## Prerequisites

| Stage | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | Pushover account, one application (token) for the Alertmanager, and the user key. Item `pushover-alertmanager` (`kubernetes` vault: `username`->pushover `user-key`, `credential`->pushover `token`). | Pushover, 1Password | Done |
| 1 | A healthchecks.io check for the dead man's switch, its ping URL in the `kube-cluster01-alertmanager` field of the `healthchecks` item. Period 1 minute, grace 3 minutes. | healthchecks.io, 1Password | Done |
| 2 | The Flux application `observability/prometheus-operator-crds`, and its release in `bootstrap/helmfile/crds.yaml.gotmpl` (the template reads its `ocirepository.yaml`), both written. Then `just bootstrap crds` on the existing cluster **before the push of stage 2**: the monitors enabled in the other charts need the CRDs, and Flux takes them over at the install of the release. | [cluster](../cluster/bootstrap.md) | To do |
| 2 | In the Pocket ID: the groups `grafana_admins` and `grafana_viewers` with their members, and a confidential OIDC client for Grafana (callback `https://grafana.shelltopia.org/login/generic_oauth`, scopes `openid profile email groups`). Item `pocket-id-grafana` (`kubernetes` vault, [naming](../secrets/README.md#naming-of-the-items)): `username` is the client id, `credential` the secret. No local password. | Pocket ID, 1Password | Done |
| 2 | The URLs of the endpoints of the Pocket ID, read from its `.well-known/openid-configuration`: `https://id.shelltopia.org/authorize`, `/api/oidc/token`, `/api/oidc/userinfo`, PKCE `S256` supported. | Pocket ID | Done |
| 2 | The sources of the rules and dashboards pinned or not: not pinned ([why](evaluations.md#sources-of-the-rules-and-dashboards)). | Decision | Done |
| 3 | The pinned addresses of the receivers: `192.168.19.2` and `fd38:4c4d:8f66:13::2` (logs), `192.168.19.3` and `fd38:4c4d:8f66:13::3` (Graphite), free: only `.1` and `.53` are in use ([reference](../reference.md#pinned-loadbalancer-addresses)). | Decision | Done |
| 3 | Host overrides in Unbound, `A` and `AAAA`: `syslog.kube-cluster01.shelltopia.net` and `graphite.kube-cluster01.shelltopia.net` to the addresses above ([dns](../dns/runbook.md#where-to-create-a-record)). | OPNsense | Done |
| 5 | SNMPv3 users on the MikroTik and the access point (read-only, one per device), items `sw-01-snmp` and `ap-01-snmp` in the `kubernetes` vault ([naming](../secrets/README.md#naming-of-the-items): `username`, `credential`, plus the `privacy_key` in a custom field). | Each device | Done |
| 5 | OPNsense: the rules from the device VLANs to the receiver addresses (syslog, Graphite), and from the nodes to the scraped devices if any. | OPNsense | Done |
| 5 | The FQDN of every scraped device resolves from the cluster. | Unbound | Done |

## 1. Operator, Alertmanager, Flux notifications

The first slice of the stack, so that the alert path exists before anything else.

- [x] **Deploy.** The `observability` namespace (`restricted`), the release of the stack with only the operator and `alertmanager` enabled, and the ExternalSecret `alertmanager` (the Pushover user key and token, the ping URL). The `VMAlertmanager`: two replicas spread over the nodes, a `local` volume each for the silences, the [routes](README.md#alerting) (`critical` priority 1, `warning` priority 0, `info` to a null receiver, the `Watchdog` route to healthchecks.io), `global.resolve_timeout: 1h`. Push, then:

  ```sh
  flux -n observability get ks
  flux -n observability get hr
  kubectl -n observability get vmalertmanager,pods -o wide
  ```

  Expected: the Kustomizations and the HelmRelease `Ready`, the Alertmanager pods running on two nodes, the CRDs of VictoriaMetrics installed. The healthchecks.io check stays *new* (no ping): the `Watchdog` alert only exists from [stage 4](#4-alert-rules-and-the-dead-mans-switch).

- [x] **Test the notification.** Send a test alert to the Alertmanager API through a `kubectl port-forward` (the baseline lets the node reach the pods, not the other namespaces):

  ```sh
  kubectl -n observability port-forward svc/vmalertmanager-victoria-metrics-k8s-stack 9093
  curl -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"Test","severity":"warning"}}]'
  ```

  Expected: a Pushover notification on the phone, priority 0. The same with `"severity":"critical"`: priority 1. With `"severity":"info"`: nothing.

- [x] **Flux.** A `Provider` of type `alertmanager` and an `Alert` for the failed reconciliations in every namespace (component `kubernetes/components/flux-alerts`). Network policy: ingress to the Alertmanager from the notification-controller. Break a throwaway Kustomization on purpose, then fix it.

  ```sh
  kubectl get providers.notification.toolkit.fluxcd.io,alerts.notification.toolkit.fluxcd.io -A
  ```

  Expected: one `Provider` and one `Alert` `Ready` per namespace, a notification (priority 0) when the Kustomization fails, and the alert resolved after the `resolve_timeout` (1 hour).

## 2. Metrics

- [x] **CRDs.** `prometheus-operator-crds` through the bootstrap ([prerequisites](#prerequisites)).

  ```sh
  kubectl get crd servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
  ```

  Expected: the three CRDs present.

- [x] **Network policies.** In `kubernetes/apps/kube-system/cilium/policies/`: `VMAgent` to every pod (`baseline.yaml`), and to the node ports it scrapes (`host.yaml`: kubelet 10250, etcd 2381, scheduler 10259, controller-manager 10257, node-exporter 9100, the Cilium agent 9962 and operator 9963, Hubble 9965, drbd-reactor 9942). Still in audit mode: check the flows in Hubble.

  ```sh
  hubble observe -P --from-label app.kubernetes.io/name=vmagent --verdict AUDIT
  ```

  Expected: no flow (every scrape is allowed).

- [x] **Deploy.** The `observability-agents` namespace (`privileged`, with the comment). In the stack: `vmsingle` (50 Gi `replicated`, 90 days, `-dedup.minScrapeInterval=30s`), `vmagent` (two replicas, every 30 s, the external label `cluster: kube-cluster01`), kube-state-metrics, node-exporter (in `observability-agents`), the scrapes of the kubelet, cAdvisor, the API server, the scheduler and the controller-manager, the data sources and the default dashboards (ConfigMaps for Grafana, the Job of the stack). The default rules stay disabled until [stage 4](#4-alert-rules-and-the-dead-mans-switch): the dashboards of kube-prometheus that read their recording rules stay empty until then, the others (Kubernetes views, node-exporter, VictoriaMetrics) do not need them. The Grafana release (its sidecars reading those ConfigMaps, login by OIDC only with `disable_initial_admin_creation` set from the first start, [Grafana](README.md#grafana), the `volsync` component for its volume, a route on the `internal` Gateway). In the second Kustomization (`victoria-metrics-k8s-stack-config`): the `VMNodeScrape` of etcd.

  ```sh
  flux -n observability get ks
  flux -n observability get hr
  kubectl -n observability get vmsingle,vmagent,vmnodescrape,vmservicescrape
  kubectl -n observability get cm -l grafana_dashboard=1
  kubectl -n observability get cm -l grafana_datasource=1
  kubectl -n observability-agents get pods -o wide
  ```

  Expected: the Kustomizations `Ready`, Grafana logging in through the Pocket ID without a login form (a member of `grafana_admins` is `GrafanaAdmin`, one of `grafana_viewers` is `Viewer`, a user of neither is refused), no `admin` user in *Administration → Users*, the Deployment of Grafana annotated for Reloader with the ConfigMap of the data sources (`configmap.reloader.stakater.com/reload`), the targets `up` (etcd, the scheduler and the controller-manager included), the dashboards of the nodes and the cluster showing data, and the two replicas of `VMAgent` writing the same series (deduplicated by `VMSingle`). The targets, from the API of a `VMAgent`:

  ```sh
  kubectl -n observability port-forward svc/vmagent-victoria-metrics-k8s-stack 8429
  curl -s localhost:8429/api/v1/targets | jq -r '.data.activeTargets[] | select(.health != "up") | .labels.job + " " + .scrapeUrl + " " + .lastError'
  ```

  Expected: nothing (every target `up`). The deduplication of the two replicas, from the API of `VMSingle` (port 8428, set by the chart):

  ```sh
  kubectl -n observability port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428
  curl -s localhost:8428/api/v1/query --data-urlencode 'query=max(count_over_time(up[5m]))' | jq -r '.data.result[0].value[1]'
  ```

  Expected: about 10 samples (5 minutes every 30 s), not 20.

- [x] **Enable the monitors.** The values already prepared: cert-manager, External Secrets, flux-operator, Spegel, Reloader, external-dns, k8s-gateway. Added: the ServiceMonitors of the Cilium agent, the Cilium operator and Hubble, CoreDNS (`prometheus.monitor` of its chart), a `PodMonitor` for the Flux controllers next to `flux-instance` (from the Flux monitoring documentation), Piraeus (LINSTOR controller, drbd-reactor `:9942`, next to the `LinstorCluster`), VolSync (its ServiceMonitor, with the token of `VMAgent` added by a post-renderer) and Envoy Gateway (the controller and the proxies). The Hubble metrics: `drop` and `policy`, `sourceContext` and `destinationContext` set to `workload-name|app|reserved-identity`. The dashboards of the Cilium chart (agent, operator, Hubble), created in `observability`, the community dashboards (`gnetId` and `revision`, the Flux one by a URL pinned to a commit) and the dashboard of the denied flows. Restarts: the Cilium agent and operator, cert-manager, External Secrets.

  Expected: one target per component `up`, the Cilium agent and operator dashboards showing data (the Hubble ones only in their `drop` panels, if any drop: the flow metrics are not enabled, [open points](evaluations.md#open-points)), and the denied (audited) flows visible per workload in the dashboard *Network policies: denied flows* (empty while no flow is audited). The ServiceMonitor of k8s-gateway may copy the `lbipam` annotation to its metrics Service: check that this Service gets no LoadBalancer address.

## 3. Logs

- [ ] **Deploy.** In the stack: `vlsingle` (30 Gi `replicated`, 30 days, `-retention.maxDiskSpaceUsageBytes` at 25 GiB) and the VictoriaLogs plugin of Grafana (`grafana.plugins`, in the values of the stack for its data source and in those of Grafana). The Vector agent (pod logs, Hubble export, disk buffers in `/var/lib/vector`) in `observability-agents`. The Vector aggregator (StatefulSet, two replicas, a `local` volume each) behind its LoadBalancer Service pinned on `192.168.19.2` and `fd38:4c4d:8f66:13::2` (`externalTrafficPolicy: Local`, [ports](README.md#logs)). Network policies: the agent to VictoriaLogs, the aggregator from `world` (the agent, the kubelet and Talos from `host` through the baseline).

  ```sh
  flux -n observability get ks,hr
  flux -n observability-agents get ks,hr
  kubectl -n observability get vlsingle,pods -o wide
  kubectl -n observability-agents get pods -o wide
  kubectl -n observability get svc vector-aggregator -o wide
  dig +short syslog.kube-cluster01.shelltopia.net A syslog.kube-cluster01.shelltopia.net AAAA
  ```

  Expected: the Kustomizations `Ready`, a Vector agent per node, the Service of the aggregator on its pinned addresses (without address, another Service holds one of them), the names resolving to them. The data source *VictoriaLogs* in Grafana (Grafana restarted by Reloader). In *Explore*, VictoriaLogs:

  - `log_source:pods`: the logs of every namespace, with `node` and the `kubernetes.*` fields;
  - `log_source:hubble flow.verdict:AUDIT`: the audited flows of every node, searchable by namespace (`flow.source.namespace:observability`), with their short message.

  The Vector jobs `up` and without errors, from the APIs of `VMAgent` and `VMSingle` (port-forwards of [stage 2](#2-metrics)):

  ```sh
  curl -s localhost:8429/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job | test("vector")) | .labels.job + " " + .health'
  curl -s localhost:8428/api/v1/query --data-urlencode 'query=sum by (job, component_id) (increase(vector_component_errors_total[1h]))' | jq -c '.data.result[] | [.metric, .value[1]]'
  hubble observe -P --verdict AUDIT --to-label app.kubernetes.io/name=vlsingle
  ```

  Expected: the agent and aggregator pods `up` (two each), no error, no audited flow to VictoriaLogs.

- [ ] **Talos.** `talos/patches/logging.yaml.j2`: `machine.logging.destinations` (service logs) and `KmsgLogConfig` (kernel logs), in `json_lines` to the hostPorts of the Vector agent of the node, `127.0.0.1:6051` and `127.0.0.1:6050`. The agent with its hostPorts first, then `just talos diff`, then the apply on one node first.

  ```sh
  kubectl -n observability-agents get ds vector-agent -o jsonpath='{.spec.template.spec.containers[0].ports}{"\n"}'
  just talos diff
  just talos apply-node kube-01
  hubble observe -P --verdict AUDIT --to-label app.kubernetes.io/name=vector-agent --since 10m
  ```

  Expected: the hostPorts 6050 and 6051 on `127.0.0.1`, the diff limited to the two destinations, no audited flow to the agent. In *Explore*: `log_source:talos-service | stats by (node) count()` and the same for `talos-kernel`, a line per node with its short name. Then the other node.

- [ ] **Source address of the syslog** (`externalTrafficPolicy: Local`). From the workstation (the OPNsense rules must let it reach the aggregator on 514), over TCP then UDP:

  ```sh
  logger --tcp -n syslog.kube-cluster01.shelltopia.net -P 514 'stage 3 test, TCP'
  logger --udp -n syslog.kube-cluster01.shelltopia.net -P 514 'stage 3 test, UDP'
  ```

  Expected: in *Explore*, `log_source:syslog "stage 3 test"` returns both lines, `source_ip` being the address of the workstation (not a node address).

- [ ] **Failover.** Stop the pod of VictoriaLogs (or, once kube-02 joined, the node that holds it): Vector buffers, then delivers when it is back. Not tested until the three nodes run.

Once the logs and the drops are visible, the [network policies can be enforced](../cluster/bootstrap.md#network-policies).

## 4. Alert rules and the dead man's switch

- [ ] **Rules.** In the stack: `vmalert` (two replicas), which evaluates the default rules, with `KubeCPUOvercommit` and `KubeMemoryOvercommit` disabled. In the second Kustomization: the `VMRule`s of the [roadmap](../roadmap.md#observability) (certificates, VolSync, DRBD and LINSTOR, Flux, the disks of the nodes and the thin pool, the flows denied by the network policies) and the errors of Vector. Check each one by provoking it when it is cheap to.

  Expected: the rules loaded without error in both `vmalert`, no alert firing on a healthy cluster except `Watchdog`.

- [ ] **Dead man's switch.** The `Watchdog` alert reaches its route to the healthchecks.io check.

  Expected: the check is up. Scale the Alertmanager to zero: healthchecks.io notifies by its own channel within 4 minutes. Then drop the healthchecks checks of the backups if the alerts replace them ([backups](../backups/README.md#monitoring)).

- [ ] **Noise.** Two weeks later: the alerts received, the rules to disable or to change ([open points](evaluations.md#open-points)).

## 5. External devices

One device at a time, in this order: the NAS, the switch, the firewall, the access point, the HTTP checks. Each one is a metrics source and a log source, with the points to [verify](evaluations.md#to-verify) first.

- [ ] **Graphite.** The Graphite listener of `VMAgent` behind its LoadBalancer Service pinned on `192.168.19.3` and `fd38:4c4d:8f66:13::3` (`graphite.kube-cluster01.shelltopia.net`), ingress from `world`.
- [ ] **HTTP checks.** `blackbox_exporter` and a `VMProbe` for Uptime Kuma and Pocket ID, egress by FQDN.
- [ ] **NAS.** The Graphite exporter (*Reporting → Exporters*) towards `192.168.19.3` (the exporter takes an IP only), remote syslog towards the aggregator.
- [ ] **MikroTik.** `snmp_exporter` (SNMPv3) and the remote logging action towards the aggregator.
- [ ] **OPNsense.** `os-node_exporter` and remote syslog.
- [ ] **Access point.** `snmp_exporter` and syslog.

Expected, for each: the device in the dashboards, its logs searchable by host, and an alert when it stops answering.
