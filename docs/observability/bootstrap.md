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

  Expected: one `Provider` and one `Alert` `Ready` per namespace, a notification (priority 0) when the Kustomization fails, and the alert resolved after the `resolve_timeout` (1 hour). Replaced at stage 4 by rules on the metrics of the flux-operator ([Flux alerts from the metrics](#4-alert-rules-and-the-dead-mans-switch)).

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

- [x] **Deploy.** In the stack: `vlsingle` (30 Gi `replicated`, 30 days, `-retention.maxDiskSpaceUsageBytes` at 25 GiB) and the VictoriaLogs plugin of Grafana (`grafana.plugins`, in the values of the stack for its data source and in those of Grafana). The Vector agent (pod logs, Hubble export, disk buffers in `/var/lib/vector`) in `observability-agents`. The Vector aggregator (StatefulSet, two replicas, a `local` volume each) behind its LoadBalancer Service pinned on `192.168.19.2` and `fd38:4c4d:8f66:13::2` (`externalTrafficPolicy: Local`, [ports](README.md#logs)). Network policies: the agent to VictoriaLogs, the aggregator from `world` (the agent, the kubelet and Talos from `host` through the baseline).

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

- [x] **Talos.** `talos/patches/logging.yaml.j2`: `machine.logging.destinations` (service logs) and `KmsgLogConfig` (kernel logs), in `json_lines` to the hostPorts of the Vector agent of the node, `127.0.0.1:6051` and `127.0.0.1:6050`. The agent with its hostPorts first, then `just talos diff`, then the apply on one node first.

  ```sh
  kubectl -n observability-agents get ds vector-agent -o jsonpath='{.spec.template.spec.containers[0].ports}{"\n"}'
  just talos diff
  just talos apply-node kube-01
  hubble observe -P --verdict AUDIT --to-label app.kubernetes.io/name=vector-agent --since 10m
  ```

  Expected: the hostPorts 6050 and 6051 on `127.0.0.1`, the diff limited to the two destinations, no audited flow to the agent. In *Explore*: `log_source:talos-service | stats by (node) count()` and the same for `talos-kernel`, a line per node with its short name. Then the other node.

- [x] **Source address of the syslog** (`externalTrafficPolicy: Local`). From the workstation (the OPNsense rules must let it reach the aggregator on 514), over TCP then UDP:

  ```sh
  logger --tcp -n syslog.kube-cluster01.shelltopia.net -P 514 'stage 3 test, TCP'
  logger --udp -n syslog.kube-cluster01.shelltopia.net -P 514 'stage 3 test, UDP'
  ```

  Expected: in *Explore*, `log_source:syslog "stage 3 test"` returns both lines, `source_ip` being the address of the workstation (not a node address).

- [ ] **Failover.** Stop the pod of VictoriaLogs (or, once kube-02 joined, the node that holds it): Vector buffers, then delivers when it is back. Not tested until the three nodes run.

Once the logs and the drops are visible, the [network policies can be enforced](../cluster/bootstrap.md#network-policies).

## 4. Alert rules and the dead man's switch

Two pushes: **4a** `vmalert`, the default rules and the dead man's switch, checked before **4b**, the rules of the repository.

- [x] **Deploy `vmalert` (4a).** In the stack: `vmalert` (two replicas spread over the nodes, every 30 s, `remoteWrite` and `remoteRead` to `VMSingle`, a notifier per Alertmanager replica), its datasource the internal `VMAuth` of the chart (two replicas, `/select/logsql/` to `VLSingle`, the rest to `VMSingle`), the links of the alerts to an *Explore* of Grafana (`external.grafana.host`), the default rules with `KubeCPUOvercommit` and `KubeMemoryOvercommit` disabled. In the Alertmanager: the route of `InfoInhibitor` to `"null"`, the short Pushover template (its link to the notifications in Grafana), the inhibition on the labels of the instances ([alerting](README.md#alerting)). Push, then:

  ```sh
  flux -n observability get hr
  kubectl -n observability get vmalert,vmauth
  kubectl -n observability get pods -o wide -l 'app.kubernetes.io/name in (vmalert,vmauth)'
  kubectl -n observability get vmrule
  hubble observe -P --verdict AUDIT --from-label app.kubernetes.io/name=vmalert --since 10m
  hubble observe -P --verdict AUDIT --from-label app.kubernetes.io/name=vmauth --since 10m
  ```

  Expected: the HelmRelease `Ready`, the `VMAlert` and the `VMAuth` `operational`, two pods of each on two nodes, the `VMRule`s of the default sources (created by the sync-job), no audited flow.

- [x] **Rules loaded.** In each `vmalert` pod (a port-forward each):

  ```sh
  kubectl -n observability get pods -l app.kubernetes.io/name=vmalert -o name
  kubectl -n observability port-forward <pod> 8080
  curl -s localhost:8080/api/v1/rules | jq -r '.data.groups[].rules[] | select(.health != "ok") | .name + " " + .lastError'
  curl -s localhost:8080/api/v1/rules | jq '[.data.groups[].rules[]] | length'
  curl -s localhost:8080/api/v1/rules | jq -r '.data.groups[].rules[] | select(.name | test("^Kube(CPU|Memory)Overcommit$")) | .name'
  ```

  Expected: in both replicas, no rule without `health` `ok`, the same number of rules, no `KubeCPUOvercommit` nor `KubeMemoryOvercommit`.

- [x] **Healthy cluster.** From the same port-forward:

  ```sh
  curl -s localhost:8080/api/v1/alerts | jq -r '.data.alerts[] | select(.state == "firing") | .labels.alertname + " " + .labels.severity + " " + (.labels.namespace // "")'
  curl -s localhost:8080/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "Watchdog") | .source'
  ```

  Expected: `Watchdog` firing, and `InfoInhibitor` with the `info` alerts if any; anything else is fixed, or noted for the noise pass (below). The link of `Watchdog`, opened in a browser: an *Explore* of Grafana on its expression (`vector(1)`), from the start of the alert.

- [x] **Dead man's switch.** The healthchecks.io check is up, one ping a minute. Then, the Alertmanager stopped (the HelmRelease suspended, or Flux would scale it back):

  ```sh
  flux -n observability suspend hr victoria-metrics-k8s-stack
  kubectl -n observability patch vmalertmanager victoria-metrics-k8s-stack --type merge -p '{"spec":{"replicaCount":0}}'
  ```

  Expected: healthchecks.io notifies by its own channel within 4 minutes (period 1 minute, grace 3). Then:

  ```sh
  kubectl -n observability patch vmalertmanager victoria-metrics-k8s-stack --type merge -p '{"spec":{"replicaCount":2}}'
  flux -n observability resume hr victoria-metrics-k8s-stack
  ```

  Expected: the two Alertmanager pods back, the check up again. The alerts of `vmalert` about its notifiers may fire meanwhile, then resolve.

- [x] **Template.** A test alert to the Alertmanager API, then the same one resolved (an `endsAt` in the past). Sent to **both replicas**, as `vmalert` does: the replicas share the silences and the notifications sent, not the alerts. Through the Service (as at [stage 1](#1-operator-alertmanager-flux-notifications)), the alert reaches one replica only, and Grafana, which reads the other one through the same Service, does not show it. A port-forward per pod, each in its own terminal:

  ```sh
  kubectl -n observability port-forward pod/vmalertmanager-victoria-metrics-k8s-stack-0 9093
  kubectl -n observability port-forward pod/vmalertmanager-victoria-metrics-k8s-stack-1 9094:9093
  ```

  Then:

  ```sh
  for p in 9093 9094; do curl -XPOST localhost:$p/api/v2/alerts -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"Test","severity":"warning","namespace":"debug"},"annotations":{"summary":"Stage 4 template test."},"generatorURL":"https://grafana.shelltopia.org/explore"}]'; done
  for p in 9093 9094; do curl -XPOST localhost:$p/api/v2/alerts -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"Test","severity":"warning","namespace":"debug"},"annotations":{"summary":"Stage 4 template test."},"generatorURL":"https://grafana.shelltopia.org/explore","endsAt":"2026-01-01T00:00:00Z"}]'; done
  ```

  Expected: one notification (not two), `[FIRING:1] Test (debug)` as the title, `Stage 4 template test.` as the body, a *Grafana* link opening *Alerting → Active notifications* on the `Alertmanager` data source, filtered on `alertname="Test",namespace="debug"`: the alert, its *See source* button opening the `generatorURL`, its *Silence* button. Then `[RESOLVED] Test (debug)` and `[resolved] Stage 4 template test.` (the link opens an empty list: the alert has left the Alertmanager). The same alert without `summary` but with a `description` shows the description; with neither, `(no details)`.

- [x] **`InfoInhibitor`.** Its route, from the same port-forwards:

  ```sh
  for p in 9093 9094; do curl -XPOST localhost:$p/api/v2/alerts -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"InfoInhibitor","severity":"none"}}]'; done
  ```

  Expected: nothing on the phone (without its route, the default receiver would notify it).

- [x] **Inhibition.** A `critical` and a `warning` of the same name on the same certificate, then on two:

  ```sh
  for p in 9093 9094; do curl -XPOST localhost:$p/api/v2/alerts -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"TestInhibitSame","severity":"critical","namespace":"debug","name":"a"}},{"labels":{"alertname":"TestInhibitSame","severity":"warning","namespace":"debug","name":"a"}}]'; done
  for p in 9093 9094; do curl -XPOST localhost:$p/api/v2/alerts -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"TestInhibitOther","severity":"critical","namespace":"debug","name":"a"}},{"labels":{"alertname":"TestInhibitOther","severity":"warning","namespace":"debug","name":"b"}}]'; done
  ```

  Expected: `TestInhibitSame` once, priority 1 (the `warning` inhibited); `TestInhibitOther` twice, priority 1 and priority 0. They resolve after the `resolve_timeout` (5 minutes, 1 hour while the Flux events were there), or at once sent again with `"endsAt":"2026-01-01T00:00:00Z"`.

- [x] **Flux events to both replicas.** Superseded by the next step the same day. The component `flux-alerts` had a `Provider` and an `Alert` per Alertmanager replica (each on its pod through the headless Service), for the same reason; checked with a throwaway Kustomization: one notification, the alert in both replicas.

- [x] **Flux alerts from the metrics (fix of 4a).** The events of the notification-controller are dropped ([why](evaluations.md#rejected-and-alternative-options)): the component `flux-alerts` leaves every namespace (its `Provider`s and `Alert`s pruned), with the network policy from the notification-controller to the Alertmanager and `resolve_timeout: 1h` (back to the default, 5 minutes). Instead, `prometheusrule.yaml` next to the flux-operator, on its `flux_resource_info` and `flux_instance_info` (`FluxResourceNotReady`, `FluxResourceSuspended`, `FluxMetricsAbsent`, [alerting](README.md#alerting)), and `reporting.interval: 30s` on the operator. Push, then:

  ```sh
  kubectl get providers.notification.toolkit.fluxcd.io,alerts.notification.toolkit.fluxcd.io -A
  kubectl -n observability get ciliumnetworkpolicy
  kubectl -n flux-system get prometheusrule,vmrule
  kubectl -n flux-system get deploy flux-operator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REPORTING_INTERVAL")].value}'
  ```

  Expected: no `Provider` nor `Alert` left, the `vlsingle` policy only, the `PrometheusRule` `flux` and its `VMRule` (converted by the operator), `30s`. In each `vmalert` pod (the port-forwards of *Rules loaded*):

  ```sh
  curl -s localhost:8080/api/v1/rules | jq -r '.data.groups[] | select(.name == "flux") | .rules[] | .name + " " + .health'
  ```

  Expected: `FluxResourceNotReady`, `FluxResourceSuspended` and `FluxMetricsAbsent`, `ok`, nothing firing. Then a throwaway Kustomization on a path that does not exist, and a second one that depends on it:

  ```sh
  kubectl -n debug apply -f - <<'EOF'
  apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: stage-4-test
  spec:
    interval: 10m
    path: ./does-not-exist
    prune: true
    sourceRef:
      kind: GitRepository
      name: flux-system
      namespace: flux-system
  ---
  apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: stage-4-test-dependent
  spec:
    dependsOn:
      - name: stage-4-test
    interval: 10m
    path: ./does-not-exist
    prune: true
    sourceRef:
      kind: GitRepository
      name: flux-system
      namespace: flux-system
  EOF
  flux -n debug get ks
  ```

  Expected: both not ready, the second one with `DependencyNotReady`. About 11 minutes later (the report, the `for`), one notification: `[FIRING:1] FluxResourceNotReady (debug)`, `Kustomization stage-4-test not ready: <the reason of flux get>.`, nothing for `stage-4-test-dependent`. Then suspended:

  ```sh
  flux -n debug suspend ks stage-4-test
  ```

  Expected: `[RESOLVED] FluxResourceNotReady (debug)` within 5 minutes (the `group_interval`), and `max by (exported_namespace, kind, name) (flux_resource_info{suspended="True"})` in *Explore* returns `stage-4-test` (the expression of `FluxResourceSuspended`, not waited for 24 hours). Then:

  ```sh
  kubectl -n debug delete kustomization stage-4-test stage-4-test-dependent
  ```

  Last, the flux-operator stopped (its HelmRelease suspended, or Flux would scale it back):

  ```sh
  flux -n flux-system suspend hr flux-operator
  kubectl -n flux-system scale deploy flux-operator --replicas 0
  ```

  Expected: `[FIRING:1] FluxMetricsAbsent (flux-system)` after about 15 minutes. Not `TargetDown`: without a pod, the target is gone, not down. Then:

  ```sh
  kubectl -n flux-system scale deploy flux-operator --replicas 1
  flux -n flux-system resume hr flux-operator
  ```

  Expected: the operator back, `[RESOLVED] FluxMetricsAbsent (flux-system)` within 5 minutes.

- [x] **Render of the sync-job (4b, before the push).** In the stack: the mixins of cert-manager, CoreDNS and Cilium (`defaultRules.sources`), the `job` of CoreDNS rewritten, the groups and rules not used disabled ([alerting](README.md#alerting)). The `VMRule`s the sync-job would create, rendered locally (it has no kubeconfig with `OUTPUT=-`: nothing reaches the cluster):

  ```sh
  yq '.spec.values' kubernetes/apps/observability/victoria-metrics-k8s-stack/app/helmrelease.yaml > /tmp/values.yaml
  helm template victoria-metrics-k8s-stack oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack --version 0.97.1 \
    -n observability -f /tmp/values.yaml --show-only templates/sync-job/config.yaml | yq '.data["config.yaml"]' > /tmp/sync-job.yaml
  podman run --rm -e OUTPUT=- -e NAMESPACE=observability -e RELEASE=victoria-metrics-k8s-stack \
    -e RESOURCE_PREFIX=victoria-metrics-k8s-stack -e PRUNE=false -e OWNER_REFERENCES=false \
    -v /tmp/sync-job.yaml:/etc/config/config.yaml:ro,Z ghcr.io/victoriametrics/sync-job:v0.0.17 > /tmp/vmrules.yaml
  yq -N 'select(.kind == "VMRule") | .spec.groups[].name' /tmp/vmrules.yaml | sort
  yq -N 'select(.kind == "VMRule") | .spec.groups[] | select(.name | test("^coredns")) | .rules[].expr' /tmp/vmrules.yaml | grep -c 'job=~"coredns-metrics|k8s-gateway-metrics"'
  yq -N 'select(.kind == "VMRule") | .spec.groups[].rules[] | select(.alert == "RunningOutOfCiliumClusterIdentities" or .alert == "CiliumAgentHighDeniedRate") | .alert' /tmp/vmrules.yaml
  yq 'select(.kind == "VMRule") | {"groups": .spec.groups}' /tmp/vmrules.yaml > /tmp/rules.yaml
  vmalert -dryRun -rule /tmp/rules.yaml
  ```

  Expected: the groups `cert-manager`, `certificates`, `coredns`, `coredns_forward` and the Cilium ones (`Cilium API`, `Conntrack`, `Endpoints`, `Identity`, `Maps`, `NAT`, `Nodes`, `Policy`) next to the default ones, each name once; no `Cilium IPAM`, `Clustermesh`, `Kvstoremesh` nor `Drops` (its only rule duplicates `NetworkPolicyDroppedFlows`: disabled as a group, a group without rules would still be created); 9 CoreDNS expressions on both jobs; neither disabled rule; `vmalert -dryRun` without error. It does not execute the templates: the one of `RunningOutOfCiliumClusterIdentities` (`{{ value }}` without argument) passes it, and fails at each notification.

- [x] **Pairs of severities (4b, before the push).** The alerts with two severities, on the render of the previous step (`/tmp/rules.yaml`) plus the `PrometheusRule`s and the `VMRule` of the repository and the upstream rules of Piraeus (`config/extras/monitoring/alerts.yaml` of the tag `v2.12.0`, a `PrometheusRule` too):

  ```sh
  curl -fsSL https://raw.githubusercontent.com/piraeusdatastore/piraeus-operator/v2.12.0/config/extras/monitoring/alerts.yaml > /tmp/piraeus-alerts.yaml
  {
    yq -o json -I0 '.groups[].rules[] | select(.alert) | {"alert": .alert, "severity": .labels.severity}' /tmp/rules.yaml
    yq -o json -I0 '.spec.groups[].rules[] | select(.alert) | {"alert": .alert, "severity": .labels.severity}' \
      kubernetes/apps/*/*/*/prometheusrule.yaml kubernetes/apps/observability/victoria-metrics-k8s-stack/config/vmrule-selinux.yaml /tmp/piraeus-alerts.yaml
  } | jq -rs 'group_by(.alert) | map(select(map(.severity) | unique | length > 1)) | .[] | .[0].alert + ": " + (map(.severity) | join(", "))'
  ```

  Expected, beyond the pairs of the default rules: `CertManagerCertExpirySoon` (instances told apart by `exported_namespace` and `name`, ours aggregated like the upstream one), `CoreDNSErrorsHigh` and `CoreDNSForwardErrorsHigh` (one per `namespace`: the two jobs are in `kube-system` and `network`), `linstorStoragePoolAtCapacity` (`node`, with `storage_pool` equal on both sides of an inhibition of the same `node`: one pool per node). Each instance label in the `equal` of the inhibition.

- [x] **Deploy (4b).** In the stack: the mixins (above), the `ReplicationSource`s in kube-state-metrics (`customResourceState`, its RBAC). Next to the applications, each in the `kustomization.yaml` of its folder: the `PrometheusRule`s of the certificates (`CertManagerCertExpirySoon` `critical`), VolSync, the denied flows, Vector (agent and aggregator), LINSTOR (`linstorStoragePoolAtCapacity` `critical`). The upstream rules of Piraeus: the `GitRepository` `piraeus-operator` (the tag of the chart, Renovate updating both in one PR) and the Flux Kustomization `piraeus-alerts`. In the second Kustomization of the stack: the `VMRule` `selinux` (LogsQL). Push, then:

  ```sh
  flux -n observability get hr
  flux -n piraeus-datastore get sources git
  flux -n piraeus-datastore get ks
  flux -n piraeus-datastore tree ks piraeus-alerts
  kubectl get prometheusrule -A
  kubectl -n observability get vmrule
  ```

  Expected: the HelmRelease `Ready`, the `GitRepository` `piraeus-operator` `Ready` on `v2.12.0`, the Kustomization `piraeus-alerts` `Ready`, its inventory the `PrometheusRule` `piraeus-datastore` alone. The `PrometheusRule`s `cert-manager`, `volsync`, `network-policies`, `vector-agent`, `vector-aggregator`, `linstor`, `piraeus-datastore` and `flux`, each with its `VMRule` (converted by the operator). In `observability`, the `VMRule`s of the mixins (created by the sync-job) and `selinux`.

- [x] **ReplicationSources in kube-state-metrics.** In *Explore*, `VictoriaMetrics`:

  ```promql
  kube_volsync_replicationsource_created
  kube_volsync_replicationsource_status_last_sync_time
  kube_volsync_replicationsource_spec_paused
  (time() - kube_volsync_replicationsource_status_last_sync_time) / 3600
  ```

  Expected: one series each for `grafana` (`namespace="observability"`), timestamps in seconds (not 0, not 1), `spec_paused` at 0, the hours since the last backup under 26 (the expression of `VolSyncBackupLate`, level 3).

- [x] **Rules loaded (4b).** In each `vmalert` pod (the port-forwards of *Rules loaded*, 4a):

  ```sh
  curl -s localhost:8080/api/v1/rules | jq -r '.data.groups[].rules[] | select(.health != "ok") | .name + " " + .lastError'
  curl -s localhost:8080/api/v1/rules | jq -r '.data.groups[] | select(.name | test("^(cert-manager|certificates|coredns|coredns_forward|Cilium .*|linstor.rules|drbd.rules|linstor|cert-manager-expiry|volsync|network-policies|vector-agent|vector-aggregator|selinux)$")) | .name + " " + (.rules | length | tostring)'
  curl -s localhost:8080/api/v1/alerts | jq -r '.data.alerts[] | select(.state == "firing") | .labels.alertname + " " + .labels.severity + " " + (.labels.namespace // "")'
  ```

  Expected: in both replicas, no rule without `health` `ok` (`selinux` included: `vmalert` reaches VictoriaLogs through the `VMAuth`); the groups with their number of rules: `cert-manager` 1, `certificates` 3, `coredns` 4, `coredns_forward` 5, `Cilium API` 1, `Cilium Conntrack` 2, `Cilium Endpoints` 4, `Cilium Identity` 1, `Cilium Maps` 2, `Cilium NAT` 1, `Cilium Nodes` 1, `Cilium Policy` 1, `linstor.rules` 6, `drbd.rules` 8, `linstor` 1, `cert-manager-expiry` 1, `volsync` 4, `network-policies` 2, `vector-agent` 4, `vector-aggregator` 4, `selinux` 1; nothing firing beyond `Watchdog` and the `info` alerts (an audited flow may show as `NetworkPolicyAuditedFlows`: fixed, or noted for the noise pass).

- [x] **Certificate expiry (level 3).** No certificate is made to expire: their remaining time and their renewal window, the expressions of the two severities without their threshold, in *Explore*:

  ```promql
  avg by (exported_namespace, namespace, name) ((certmanager_certificate_expiration_timestamp_seconds - time()) and on (exported_namespace, namespace, name) (certmanager_certificate_ready_status{condition="True"} == 1)) / 86400
  avg by (exported_namespace, namespace, name) (certmanager_certificate_expiration_timestamp_seconds - certmanager_certificate_renewal_timestamp_seconds) * 0.7 / 86400
  ```

  Expected: one series per certificate, with its days left (over 30: renewed 30 days before its end), and 21 days for the upstream `warning` (0.7 of the renewal window of 30 days); ours fires at 7.

- [x] **Certificate not ready, state restored.** A `Certificate` on an `Issuer` that does not exist:

  ```sh
  kubectl -n debug apply -f - <<'EOF'
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata:
    name: stage-4-test
  spec:
    secretName: stage-4-test
    dnsNames:
      - stage-4-test.invalid
    issuerRef:
      kind: Issuer
      name: does-not-exist
  EOF
  kubectl -n debug get certificate stage-4-test
  ```

  Expected: `READY` `False`, then after about 10 minutes one notification, priority 1: `[FIRING:1] CertManagerCertNotReady (cert-manager)` (the `namespace` is the one of cert-manager, which exports the metric; the certificate's is `exported_namespace`), The cert `stage-4-test` is not ready to serve traffic. Then, while it fires, both `vmalert` pods restarted at once:

  ```sh
  kubectl -n observability delete pod -l app.kubernetes.io/name=vmalert
  kubectl -n observability get pods -l app.kubernetes.io/name=vmalert -w
  ```

  Expected: the pods back, `CertManagerCertNotReady` firing again in their `/api/v1/alerts` with the same `activeAt` (its state read back from `VMSingle` by `remoteRead`), and nothing on the phone: no `[RESOLVED]` then `[FIRING]`. Then:

  ```sh
  kubectl -n debug delete certificate stage-4-test
  ```

  Expected: `[RESOLVED] CertManagerCertNotReady (cert-manager)` within 5 minutes.

- [x] **VolSync paused.** The Kustomization of Grafana suspended (so that Flux cannot revert the patch), then its `ReplicationSource` paused for an hour and a half, away from its schedule (01:30 UTC):

  ```sh
  flux -n observability suspend ks grafana
  kubectl -n observability patch replicationsource grafana --type merge -p '{"spec":{"paused":true}}'
  ```

  Expected: `kube_volsync_replicationsource_spec_paused{name="grafana"}` at 1 within a minute, `VolSyncBackupPaused` pending, then firing after an hour, in *Alerting → Alert rules* (and in the `vmalert` API), nothing on the phone (`info`). Then:

  ```sh
  kubectl -n observability patch replicationsource grafana --type json -p '[{"op":"remove","path":"/spec/paused"}]'
  flux -n observability resume ks grafana
  ```

  Expected: the metric back to 0, the alert gone at the next evaluation.

- [x] **Audited flows.** From a pod of `debug`, a single flow no policy allows (to `VMSingle`, whose policies only admit the clients of the stack):

  ```sh
  kubectl -n debug run np-alert-test --image=docker.io/library/busybox --restart=Never --command -- \
    nc -zv -w 3 vmsingle-victoria-metrics-k8s-stack.observability.svc 8428
  kubectl -n debug wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-alert-test
  hubble observe -P --verdict AUDIT --from-pod debug/np-alert-test --since 5m
  kubectl -n debug delete pod np-alert-test
  ```

  Expected: the flow in Hubble (`AUDIT`, ingress to `vmsingle`; audited, so the connection succeeds), then within two minutes (the scrape, the evaluation) `NetworkPolicyAuditedFlows` firing (no `for`: one flow is enough), `direction="ingress"`, `source_namespace="debug"`, `namespace="observability"` (the side whose policy decides), its summary with the number of flows and both ends; nothing on the phone (`info`). The alert gone an hour later (the `increase` window). `NetworkPolicyDroppedFlows` (`rate` over 10 minutes, `for: 10m`: a sustained drop only) is checked once the policies are [enforced](../cluster/bootstrap.md#network-policies), the same flow then dropped and repeated for 25 minutes.

- [x] **Vector.** `VLSingle` stopped for 10 minutes (the HelmRelease suspended, or Flux would scale it back):

  ```sh
  flux -n observability suspend hr victoria-metrics-k8s-stack
  kubectl -n observability patch vlsingle victoria-metrics-k8s-stack --type merge -p '{"spec":{"replicaCount":0}}'
  ```

  Expected: `[FIRING] VectorSinkStalled (observability-agents)` about 15 minutes after the stop (10 minutes without a sent event, then `for: 5m`; one alert per pod and sink, `vlsingle_pods`, `vlsingle_talos`, `vlsingle_hubble`: grouped in one notification), `vector_buffer_size_bytes{job="vector-agent"}` growing in *Explore*. No `VectorComponentErrors`: Vector retries without limit and keeps the events, the failed requests only count in `vector_http_client_errors_total` (checked on 2026-11-12). The aggregator only stalls if it receives something (no external device before [stage 5](#5-external-devices)). `selinux` loses its `health` `ok` meanwhile (no VictoriaLogs to query), and the alerts of `vmalert` about its evaluations may fire. Then:

  ```sh
  kubectl -n observability patch vlsingle victoria-metrics-k8s-stack --type merge -p '{"spec":{"replicaCount":1}}'
  flux -n observability resume hr victoria-metrics-k8s-stack
  ```

  Expected: the buffers back to their level, the logs of the outage delivered (`log_source:pods | stats by (_time:1m) count()` over the last half hour, no empty minute), `[RESOLVED] VectorSinkStalled` within a few minutes, each sink at its next retry (the backoff grows with the outage: about 6 minutes for `vlsingle_hubble` after a 15-minute stop, on 2026-11-12). The buffering half of the [failover](#3-logs) of stage 3, on both nodes. `VectorComponentErrors`, `VectorBufferFillingUp` (over 80 % for 10 minutes) and `VectorDiscardedEvents` are not provoked: their expressions are checked against the cluster only.

- [x] **DRBD (optional).** A throwaway volume (`replicated-temporary`: deleted with its PVC) and a pod on kube-01:

  ```sh
  kubectl -n debug apply -f - <<'EOF'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: drbd-alert-test
  spec:
    storageClassName: replicated-temporary
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 1Gi
  ---
  apiVersion: v1
  kind: Pod
  metadata:
    name: drbd-alert-test
  spec:
    nodeSelector:
      kubernetes.io/hostname: kube-01
    containers:
      - name: sleep
        image: docker.io/library/busybox
        command: [sleep, "3600"]
        volumeMounts:
          - name: data
            mountPath: /data
    volumes:
      - name: data
        persistentVolumeClaim:
          claimName: drbd-alert-test
  EOF
  kubectl -n debug get pvc drbd-alert-test -o jsonpath='{.spec.volumeName}{"\n"}'
  kubectl -n piraeus-datastore get pods -o wide | grep satellite
  kubectl -n piraeus-datastore exec <satellite of kube-03> -- drbdadm disconnect <pvc-...>
  ```

  Expected: `[FIRING] drbdConnectionNotConnected (piraeus-datastore)` after a minute (and `drbdDeviceNotUpToDate` for the replica left behind, if DRBD outdates it). Then:

  ```sh
  kubectl -n piraeus-datastore exec <satellite of kube-03> -- drbdadm connect <pvc-...>
  kubectl -n debug delete pod drbd-alert-test
  kubectl -n debug delete pvc drbd-alert-test
  ```

  Expected: `[RESOLVED]` after the reconnection and the resync, the PV and its LINSTOR resource gone with the PVC.

- [x] **SELinux (level 3).** No denial is provoked. The expression of `SELinuxUnlabeledDenials` over 2026-11-09 and 2026-11-10 (the denials of [the mounts without context](../storage/README.md#decisions)), in *Explore*, `VictoriaLogs`:

  ```logsql
  _time:[2026-11-09T00:00:00Z, 2026-11-11T00:00:00Z) log_source:talos-service "talos-service":auditd unlabeled_t | stats by (node) count() as denials | filter denials:>0
  ```

  Expected: one line for kube-01 and one for kube-03 (`vmalert` adds its own `_time` filter, the 5 minutes of the group); over the last 24 hours, nothing (the alert not firing).

- [x] **Not provoked.** Their expressions checked against the cluster only (level 3, before the push): `VolSyncVolumeOutOfSync`, `VolSyncMissedIntervals` and `VolSyncBackupLate` (a failing backup), `VectorComponentErrors`, `VectorBufferFillingUp` and `VectorDiscardedEvents`, `linstorStoragePoolAtCapacity` (a full pool), the storage pool errors, the rules of the mixins beyond `CertManagerCertNotReady`. The metadata of the thin pool, not exposed, has no alert ([open points](evaluations.md#open-points)).

- [ ] **Noise.** Two weeks later: the alerts received, the rules to disable or to change ([open points](evaluations.md#open-points)), the overcommit rules once kube-02 joins, and the healthchecks.io checks of the backups dropped if the alerts replace them ([backups](../backups/README.md#monitoring)).

## 5. External devices

One device at a time, in this order: the NAS, the switch, the firewall, the access point, the HTTP checks. Each one is a metrics source and a log source, with the points to [verify](evaluations.md#to-verify) first.

- [ ] **Graphite.** The Graphite listener of `VMAgent` behind its LoadBalancer Service pinned on `192.168.19.3` and `fd38:4c4d:8f66:13::3` (`graphite.kube-cluster01.shelltopia.net`), ingress from `world`.
- [ ] **HTTP checks.** `blackbox_exporter` and a `VMProbe` for Uptime Kuma and Pocket ID, egress by FQDN.
- [ ] **NAS.** The Graphite exporter (*Reporting → Exporters*) towards `192.168.19.3` (the exporter takes an IP only), remote syslog towards the aggregator.
- [ ] **MikroTik.** `snmp_exporter` (SNMPv3) and the remote logging action towards the aggregator.
- [ ] **OPNsense.** `os-node_exporter` and remote syslog.
- [ ] **Access point.** `snmp_exporter` and syslog.

Expected, for each: the device in the dashboards, its logs searchable by host, and an alert when it stops answering.
