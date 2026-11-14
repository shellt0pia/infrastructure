# Cluster tools

Temporary document: the plan of the [Cluster tools](roadmap.md#cluster-tools) of the roadmap, step by step. Each step writes its decisions in its topic document and ticks its item of the roadmap in the same commit ([AGENTS.md](../AGENTS.md#do-not)). This document is deleted after the last step.

## Steps

| Step | Roadmap items | Why in this order | Status |
| --- | --- | --- | --- |
| [1](#1-resources-and-priorities) | Resources and `PriorityClass`es: the convention, the classes, the checks | The convention first: every tool deployed after it (metrics-server, VPA, Headlamp) follows it from the start. | Done |
| [2](#2-kubelet-serving-certificates-metrics-server-and-vpa) | kubelet serving certificates, metrics-server, VPA and Goldilocks | Grouped: metrics-server needs the verified kubelet certificates, the VPA recommender needs metrics-server. | Done |
| [3](#3-sizing) | Resources and `PriorityClass`es: the sizing | From the history of VictoriaMetrics (since 2026-11-03), cross-checked with the recommendations of step 2. | Applied on 2026-11-14, the check two weeks later |
| [4](#4-oidc-authentication) | Kubernetes OIDC authentication | Before the UIs: both log in through it, and their rights are the bindings of its groups. | To do |
| [5](#5-flux-web-ui-and-headlamp) | Flux web UI, Headlamp | Grouped: same pattern (a client in the Pocket ID, an `HTTPRoute` on the `internal` Gateway, the groups of step 4). The Flux UI first: nothing to deploy. | To do |
| [6](#6-descheduler) | Descheduler, `topologySpreadConstraints` | Once kube-02 joins: it uses the requests of step 3 and metrics-server of step 2. Stays in the roadmap until then. | Waits for kube-02 |

## 1. Resources and priorities

### Today

- Nodes: 16 GiB, `systemReserved` 500m and 1 GiB, `kubeReserved` 250m and 512 MiB, `evictionHard` `memory.available: 500Mi` (`talos/patches/kubernetes.yaml.j2`): about 14 GiB allocatable per node. Two nodes until kube-02 joins.
- The pattern already used by 14 manifests (the observability tools, Hubble UI, Reloader, Spegel, cloudflare-ddns, volsync-monitor): CPU and memory requests, a memory limit, no CPU limit. Nothing says why.
- No resources in the repository, the chart defaults (to check in the renders): cert-manager, Envoy Gateway (the controller, and the proxies through the `EnvoyProxy`s), External Secrets, flux-operator and the Flux controllers, the Cilium agent, operator, Envoy and Hubble Relay, CoreDNS, the Intel device plugin, snapshot-controller, external-dns, k8s-gateway, VolSync and its movers, Piraeus (operator, controller, satellites, CSI, HA controller).
- Priorities: only CoreDNS sets one (`system-cluster-critical`). The defaults of the charts to check in the renders. The Talos static pods (API server, controller-manager, scheduler) keep the settings of Talos: etcd is a Talos service, in `podruntime` (`kubeReserved`).

### How Kubernetes uses them

- Scheduling: the requests only. A pending pod preempts pods of a lower priority to find room, unless its class has `preemptionPolicy: Never`.
- Eviction by the kubelet (`evictionHard`): first the pods that use more than their request, then the lowest priority, then the largest use above the request. Never the static pods, nor the pods at `system-cluster-critical` or above: one of them that leaks makes the kubelet evict the others instead.
- OOM killer of the kernel, when the memory runs out before the kubelet acts: by QoS class, not by priority. `BestEffort` first, `Guaranteed` last, `Burstable` by the share of its request in the memory of the node.
- Memory limit: the container is killed past it, whatever the state of the node. CPU limit: the container is throttled past it, even on an idle node.

A component wins under memory pressure with a request that covers its real use, and a high priority.

### Decisions

In the [conventions](conventions.md#resources-and-priorities), the why in [cluster](cluster/README.md#resources-and-priorities), the rejected options in its [evaluations](cluster/evaluations.md#rejected-options).

### Plan

- [x] **Convention.** A *Resources and priorities* section of [conventions.md](conventions.md), the why in [cluster/README.md](cluster/README.md).
- [x] **Classes.** `kubernetes/apps/kube-system/priority-classes/`, applied before any pod names them: a pod that names an unknown class is refused. Also applied by the bootstrap helmfile, before Cilium (`presync` hook).
- [x] **Checks.** The alerts `ContainerWithoutMemoryLimit` (`info` until step 3, then `warning`) and `ContainerOOMKilled`, in `kubernetes/apps/observability/victoria-metrics-k8s-stack/app/prometheusrule.yaml`. Their checks in [bootstrap](cluster/bootstrap.md#resources-and-priorities), done on 2026-11-13.
- [x] **Inventory.** Each release rendered (`helm template`, in `.scratch/inventory/`, the charts unpacked in `.scratch/charts/`), and the pods created by an operator read in the cluster: per container, init containers and sidecars included, its requests, limits and class, and how to set them ([below](#inventory)).
- [x] **Docs:** [conventions](conventions.md), [cluster](cluster/README.md) (decisions, status and [checks](cluster/bootstrap.md#resources-and-priorities)), [observability](observability/README.md#alerting) (the rules), [reference](reference.md#priority-classes) (the classes).

### Inventory

Rendered on 2026-11-13, at the versions of the repository; the pods created by an operator read in the cluster the same day ([below](#from-the-cluster)). Requests then limits, CPU / memory; `-` for none. The Helm hooks run by Flux included (`startupapicheck`, `certgen`, `sync-job`); not the `post-delete` hooks of Spegel, only run at its removal.

| Namespace | Component: containers | Requests | Limits | Class today | Set through |
| --- | --- | --- | --- | --- | --- |
| `backups` | VolSync: `manager` | 100m / 64Mi | 1000m / 1Gi | - | chart: `resources`, `priorityClassName` |
| `backups` | VolSync movers | - | - | - | `moverResources` of the `ReplicationSource` (`kubernetes/components/volsync`). No field for the class: the one of the application (0) |
| `backups` | `volsync-monitor`: `check` | 10m / 64Mi | - / 256Mi | - | manifest |
| `cert-manager` | controller, cainjector, webhook, `startupapicheck` | - | - | - | chart: `resources`, `cainjector.resources`, `webhook.resources`, `startupapicheck.resources`, `global.priorityClassName` |
| `envoy-gateway-system` | Envoy Gateway: `envoy-gateway` | 100m / 256Mi | - / 1024Mi | - | chart: `deployment.envoyGateway.resources`, `deployment.priorityClassName` |
| `envoy-gateway-system` | `certgen` (Job) | - | - | - | chart: `certgen.job.resources`; no class value |
| `external-secrets` | controller, webhook, cert-controller | - | - | - | chart: `resources`, `priorityClassName`, the same under `webhook` and `certController` |
| `flux-system` | flux-operator: `manager` | 100m / 64Mi | 2000m / 1Gi | - | chart: `resources`, `priorityClassName` |
| `kube-system` | Cilium agent: `cilium-agent`, init containers (`install-cni-binaries` 100m / 10Mi, limit 1 / 1Gi; the others none) | - | - | `system-node-critical` | chart: `resources`, `initResources`, `priorityClassName` |
| `kube-system` | Cilium Envoy | - | - | `system-node-critical` | chart: `envoy.resources`, `envoy.priorityClassName` |
| `kube-system` | Cilium operator | - | - | `system-cluster-critical` | chart: `operator.resources`, `operator.priorityClassName` |
| `kube-system` | Hubble Relay | - | - | - | chart: `hubble.relay.resources`, `hubble.relay.priorityClassName` |
| `kube-system` | Hubble UI: `frontend`, `backend` | 10m / 16Mi, 10m / 64Mi | - / 64Mi, - / 256Mi | - | chart: `hubble.ui.frontend.resources`, `hubble.ui.backend.resources`, `hubble.ui.priorityClassName` |
| `kube-system` | Hubble `certgen` (CronJob) | - | - | - | chart: `certgen.resources`, `certgen.priorityClassName` |
| `kube-system` | CoreDNS | 100m / 128Mi | 100m / 128Mi | `system-cluster-critical` | chart: `resources`, `priorityClassName` |
| `kube-system` | Intel device plugin operator: `manager` | 100m / 100Mi | 100m / 120Mi | - | chart: `resources`; no class value (a `postRenderers` patch) |
| `kube-system` | Intel GPU plugin (DaemonSet of the operator) | 40m / 45Mi | 100m / 115Mi | - | set by the operator: `GpuDevicePlugin` has no field for either |
| `kube-system` | Reloader | 10m / 64Mi | - / 256Mi | - | chart: `reloader.deployment.resources`, `reloader.deployment.priorityClassName` |
| `kube-system` | snapshot-controller | - | - | - | chart: `controller.resources`, `controller.priorityClassName` |
| `kube-system` | Spegel: `registry`, init `configuration` | 10m / 128Mi each | - / 128Mi each | `system-node-critical` (chart default) | chart: `resources`, `priorityClassName` |
| `network` | cloudflare-ddns | 5m / 16Mi | - / 64Mi | - | manifest |
| `network` | external-dns | - | - | - | chart: `resources`, `priorityClassName` |
| `network` | k8s-gateway | 100m / 128Mi | 100m / 128Mi | - | chart: `resources`, `priorityClassName` |
| `network` | Envoy proxies of the Gateways, 2 per Gateway: `envoy`, `shutdown-manager` | 100m / 512Mi, 10m / 32Mi | - | - | `EnvoyProxy`: `envoyDeployment.container.resources`, `envoyDeployment.pod.priorityClassName`; the `shutdown-manager` through `envoyDeployment.patch` |
| `observability-agents` | Vector agent | 20m / 128Mi | - / 1Gi | - | chart: `resources`, `podPriorityClassName` |
| `observability-agents` | node-exporter | 10m / 32Mi | - / 64Mi | - | stack: `prometheus-node-exporter.resources`, `.priorityClassName` |
| `observability` | kube-state-metrics | 10m / 64Mi | - / 128Mi | - | stack: `kube-state-metrics.resources`, `.priorityClassName` |
| `observability` | VictoriaMetrics operator | 20m / 128Mi | - / 256Mi | - | stack: `victoria-metrics-operator.resources`, `.priorityClassName` |
| `observability` | `sync-job` (Job of the stack) | 10m / 64Mi | - / 256Mi | - | stack: `syncJob.resources`; no class value |
| `observability` | `VMSingle` | 100m / 512Mi | - / 1536Mi | - | `spec.resources`, `spec.priorityClassName` of the resource, in the values of the stack |
| `observability` | `VLSingle` | 50m / 256Mi | - / 1Gi | - | idem |
| `observability` | `VMAgent` | 50m / 256Mi | - / 512Mi | - | idem |
| `observability` | `VMAlert` | 20m / 64Mi | - / 256Mi | - | idem |
| `observability` | `VMAlertmanager` | 10m / 64Mi | - / 128Mi | - | idem |
| `observability` | `VMAuth` (internal) | 10m / 32Mi | - / 128Mi | - | idem |
| `observability` | `config-reloader` and init `config-init` of `VMAgent`, `VMAlert`, `VMAlertmanager`, `VMAuth` | 10m / 25Mi | - | - | `spec.configReloaderResources` of each resource |
| `observability` | Grafana: `grafana`, `grafana-sc-dashboard`, init `grafana-init-sc-datasources` | 50m / 256Mi, 10m / 64Mi, 10m / 64Mi | - / 512Mi, - / 128Mi, - / 128Mi | - | chart: `resources`, `sidecar.resources`, `priorityClassName` |
| `observability` | Grafana: init `download-dashboards` | - | - | - | chart: `downloadDashboards.resources` |
| `observability` | Vector aggregator | 20m / 64Mi | - / 512Mi | - | chart: `resources`, `podPriorityClassName` |
| `observability` | blackbox-exporter, snmp-exporter | 10m / 32Mi, 10m / 64Mi | - / 128Mi, - / 256Mi | - | chart: `resources`, `priorityClassName` |
| `observability` | mktxp (and init `config`), nut-exporter, opnsense-exporter | 10m / 64Mi (10m / 16Mi), 10m / 32Mi, 10m / 32Mi | - / 128Mi (- / 16Mi), - / 64Mi, - / 128Mi | - | app-template: `resources` of each container, `defaultPodOptions.priorityClassName` |
| `piraeus-datastore` | Piraeus operator: `manager` | - | - | `system-cluster-critical` (chart default) | chart: `resources`, `priorityClassName` |
| `piraeus-datastore` | LINSTOR controller (and init `run-migration`), CSI controller (6 containers, init `linstor-wait-api-online`) | - | - | `system-node-critical` (operator default) | `podTemplate` of `controller` and `csiController` in the `LinstorCluster` |
| `piraeus-datastore` | LINSTOR satellites: `linstor-satellite`, `drbd-reactor`, init `setup-lvm-configuration` | - | - | `system-node-critical` (operator default) | `podTemplate` of the `LinstorSatelliteConfiguration` |
| `piraeus-datastore` | CSI node (3 containers, init `linstor-wait-node-online`) | - | - | `system-node-critical` (operator default) | `podTemplate` of `csiNode` in the `LinstorCluster` |
| `piraeus-datastore` | HA controller, affinity controller | - | - | `system-cluster-critical` (operator default) | `podTemplate` of `highAvailabilityController` and `affinityController` in the `LinstorCluster` |
| `flux-system` | Flux controllers: source, kustomize, helm, notification | 50m / 64Mi (source), 100m / 64Mi | 1 / 1Gi | `system-cluster-critical` (upstream), none for notification | `kustomize.patches` of flux-instance |

What it shows:

- **Nothing names `infrastructure`.** The system classes: the Cilium agent and Envoy, the Cilium operator, CoreDNS, every pod of Piraeus, and three Flux controllers (`system-cluster-critical` upstream, not notification-controller).
- **Classes of the operators against the convention:** the LINSTOR controller and the CSI controller are `system-node-critical`, not `system-cluster-critical`. The Piraeus operator, the affinity controller and the Flux controllers are `system-cluster-critical`, not `infrastructure`. The convention wins ([cluster](cluster/README.md#resources-and-priorities)): set in [step 3](#3-sizing).
- **Without a memory limit**: cert-manager, External Secrets, the Cilium agent, Envoy and operator, Hubble Relay, snapshot-controller, external-dns, every pod of Piraeus, the Envoy proxies and their `shutdown-manager`, the config reloaders of the VictoriaMetrics resources, the Jobs of cert-manager, Envoy Gateway and Hubble, the init `download-dashboards` of Grafana, and the VolSync movers.
- **CPU limits** of the defaults, against the convention: VolSync, flux-operator and the Flux controllers, the init `install-cni-binaries` of Cilium, CoreDNS, the Intel operator, k8s-gateway. Removed in the values (`cpu: null` clears a default of the chart). The GPU plugin keeps the one of its operator.
- **Memory limit equal to the request** (chart defaults): CoreDNS, k8s-gateway, Spegel, the init of mktxp. To recheck with the sizing.
- **No field for the class**: the Intel device plugin operator (a `postRenderers` patch), the Jobs `certgen` of Envoy Gateway and `sync-job` of the stack, the VolSync movers (the class of their application), the GPU plugin (neither the resources nor the class, set by its operator: 40m / 45Mi, limits 100m / 115Mi).
- **Finished pods kept**: 77 pods of an old ReplicaSet of the Cilium operator (76 `NodeShutdown`, 1 `Terminated`), two revisions of cert-manager and k8s-gateway. `ContainerWithoutMemoryLimit` leaves them out; their cleaning is an [open point](cluster/evaluations.md#open-points).

#### From the cluster

The pods created by an operator (Flux controllers, LINSTOR, the Envoy proxies, the GPU plugin, the config reloaders of the VictoriaMetrics operator), from the live pods:

```sh
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $pod | (.spec.priorityClassName // "-") as $class | ((.spec.initContainers // []) + .spec.containers)[] | [$ns, $pod, $class, .name, (.resources.requests.cpu // "-"), (.resources.requests.memory // "-"), (.resources.limits.cpu // "-"), (.resources.limits.memory // "-")] | @tsv' > .scratch/inventory/live.tsv
```

## 2. kubelet serving certificates, metrics-server and VPA

Roadmap item ([roadmap](roadmap.md#cluster-tools)), and the tools of the sizing.

### Starting point

- The kubelets serve a self-signed certificate (no `serverTLSBootstrap` in `KubeletConfig`, `talos/patches/kubernetes.yaml.j2`). Nothing verifies it: the three `VMNodeScrape`s of the stack (`kubelet`, `cadvisor`, `probes`) have `insecureSkipVerify: true` (chart default, no `kubelet:` override in the repository). The scheduler and the controller-manager stay so (self-signed on Talos).
- The node names are short (`kube-01`, `registerWithFQDN: false`, `talos/patches/hostname.yaml.j2`), and the nodes have no search domain: `kube-01` does not resolve from a pod. The InternalIPs are the IPv4 and ULA addresses (`nodeIP.validSubnets`).
- Network: the baseline already lets the API server reach every pod (aggregated APIs) and every pod reach the cluster. Only the host firewall filters the kubelet port (TCP 10250, from `VMAgent` today).
- Alerts already there (kube-prometheus rules of the stack): `KubeletServerCertificateExpiration` and `KubeletServerCertificateRenewalErrors` (their metrics only exist once the kubelet rotates its serving certificate), `KubeAggregatedAPIDown` and `KubeAggregatedAPIErrors` (metrics-server).

### Upstream

Checked on 2026-11-13.

| Tool | Chart | Notes |
| --- | --- | --- |
| Talos 1.14 | - | `KubeletConfig` `config.serverTLSBootstrap: true` (reference). The kubelet restarts, no reboot. Until its CSR is approved, it has no serving certificate: no logs, exec or scrapes on that node. |
| `postfinance/kubelet-csr-approver` | 1.2.15, `oci://ghcr.io/postfinance/charts/kubelet-csr-approver` | Kept up to date with the last three Kubernetes minors. Checks the CSR: signer, `system:node:` user, a single DNS SAN prefixed by the node name and matching `providerRegex`, the IP SANs in `providerIpPrefixes` (all allowed when empty), and the IPs that the DNS SAN resolves to (`bypassDnsResolution`). Defaults: 2 replicas, leader election, CPU limit. |
| `alex1989hu/kubelet-serving-cert-approver` | Manifests only | Tested up to Kubernetes 1.36 (the cluster runs 1.37.1). Checks the form of the CSR (user, CN, usages), not its SANs: a node could get a certificate for any name or address. |
| metrics-server | 3.14.0 (0.9.0), `https://kubernetes-sigs.github.io/metrics-server` | Verifies the kubelets with the CA of the cluster unless `--kubelet-insecure-tls`. The API server reaches it without verification by default (`apiService.insecureSkipTLSVerify: true`); `tls.type: cert-manager` gives it a certificate and injects the CA (cainjector, deployed). Default class `system-cluster-critical`. |
| VPA | 0.16.0 (1.8.1), `https://kubernetes.github.io/autoscaler` | `admissionController.enabled` and `updater.enabled` to `false` for the recommender alone. CRDs in the templates. Defaults: 2 replicas and a PDB `minAvailable: 1`, no seccomp profile nor container `securityContext`. History in `VerticalPodAutoscalerCheckpoint`s (default), or read from Prometheus at start (`--storage=prometheus`). Minimum recommendation per pod: 25m and 250 MiB (`--pod-recommendation-min-*`). |
| Goldilocks | 11.2.1 (4.16.3), `https://charts.fairwinds.com/stable` | Its VPA and metrics-server subcharts disabled by default. Controller flags: `on-by-default`, `exclude-namespaces`, `ignore-controller-kind`. Dashboard on port 8080, 2 replicas, cost data from `insights.fairwinds.com` unless `enable-cost: false`. No field for the class, `pullPolicy: Always`. The VPAs it creates: `updateMode: Off`. |
| kube-apiserver (Talos 1.14.4) | - | `kubelet-preferred-address-types` `InternalIP,ExternalIP,Hostname`, no `kubelet-certificate-authority` (accepted in `extraArgs` of `KubeAPIServerConfig`). Its `/system/secrets/kubernetes/kube-apiserver/ca.crt` holds the accepted CAs of the cluster, the one that signs the `kubelet-serving` CSRs included. |

### Answers

1. **Approver**: `postfinance/kubelet-csr-approver`. `bypassDnsResolution: true` (the short node name does not resolve), `providerRegex` `^kube-0[1-9]$`, `providerIpPrefixes` the nodes subnets, IPv4 and ULA: without them, a node could get a certificate for any address, `10.96.0.1` included, that the pods trust through the CA of the cluster. The rule on addresses is relaxed first (Victor, the cluster addressing being stable now).
2. **Namespace**: `cluster-tools`, `restricted`, for the four tools (and later Headlamp and the descheduler). `kube-system` is exempt from Pod Security for Cilium, Spegel and the GPU plugin only: in their own namespace, Pod Security refuses a chart that turns privileged, and the same-namespace policy no longer lets an exposed UI (Goldilocks) reach Hubble Relay (every flow, no authentication) or the other pods of `kube-system`. Only the `RoleBinding` of metrics-server to `extension-apiserver-authentication-reader` stays in `kube-system` (fixed by the chart, needed by every aggregated API). Reloader and snapshot-controller may move there later, in a commit of their own (moved on 2026-11-14).
3. **metrics-server**: verified both ways. It verifies the kubelets with the CA of the cluster, the API server verifies it (`tls.type: cert-manager`, `insecureSkipTLSVerify: false`, `dependsOn` cert-manager).
4. **VPA history**: checkpoints (default). VictoriaMetrics stays the cross-check of [step 3](#3-sizing).
5. **VPA minimums** lowered: `--pod-recommendation-min-cpu-millicores=5`, `--pod-recommendation-min-memory-mb=16`.
6. **Goldilocks access**: `kubernetes_admins`, as Hubble UI.
7. **Monitoring**: the existing rules only. A failed approval shows as `KubeletServerCertificateRenewalErrors`, metrics-server as `KubeAggregatedAPIDown`; VPA and Goldilocks are covered by the generic rules (`KubePodCrashLooping`, `FluxResourceNotReady`).
8. **The API server verifies the kubelets** as soon as both nodes have their certificate: `kubelet-certificate-authority` in a `KubeAPIServerConfig`. Not in the same apply as `serverTLSBootstrap`: the API server of a node would refuse the kubelet of the other until its certificate is signed.
9. **Approver at bootstrap**: with `serverTLSBootstrap` in the Talos config, a new cluster has no kubelet serving certificate until the approver runs (no `kubectl logs` nor `exec` before Flux). In the bootstrap helmfile, after Cilium: it needs no DNS (`bypassDnsResolution`).

### Commits

One commit per item, pushed after the checks of the previous one. Every release: the conventions (requests, a memory limit, no CPU limit, class `infrastructure` and `dependsOn` `priority-classes`, `restricted` securityContext, 1 replica and no PDB).

- [x] **Approver.** The namespace `cluster-tools`, its release and the bootstrap helmfile, values of [decision 1](#answers), the rule on addresses relaxed ([conventions](conventions.md#addresses)). Check: running, no CSR denied ([bootstrap](cluster/bootstrap.md#kubelet-serving-certificates)).
- [x] **Talos: kubelets.** `serverTLSBootstrap: true` in `KubeletConfig`. Applied by Victor, `just talos diff` then one node, then the other. Check per node: its `kubelet-serving` CSR `Approved,Issued`, the certificate signed by the cluster CA with the IPv4 and ULA addresses, `kubectl logs` of a pod of the node ([bootstrap](cluster/bootstrap.md#kubelet-serving-certificates)).
- [x] **Talos: API server.** `KubeAPIServerConfig` `extraArgs` `kubelet-certificate-authority: /system/secrets/kubernetes/kube-apiserver/ca.crt`, in `kubernetes.yaml.j2`, merged by Talos with the one of `cluster-rename.yaml` (`just talos diff`). One node, then the other. Check through each API server: `kubectl logs` and `exec` of a pod of each node ([bootstrap](cluster/bootstrap.md#kubelet-serving-certificates)).
- [x] **metrics-server and the scrapes.** Its release, TCP 10250 from its pods in the host firewall, and the kubelet `VMNodeScrape`s of the stack verified (`kubelet.vmScrape.spec.tlsConfig.insecureSkipVerify: false`). Check: `kubectl top nodes`, the targets of `VMAgent` up.
- [x] **VPA recommender.** Admission controller and updater disabled, checkpoints, the minimums of [decision 5](#answers), the restricted `securityContext` (none by default). Check: a test VPA in `debug` gets a recommendation.
- [x] **Goldilocks.** Controller and dashboard (`on-by-default` on both, `enable-cost: false`, `pullPolicy: IfNotPresent`), the class by `postRenderers`. The `HTTPRoute` `goldilocks.shelltopia.org` on the `internal` Gateway, the `SecurityPolicy`, the `ExternalSecret` of `pocket-id-goldilocks` ([UI pattern](ingress/runbook.md#a-ui-without-a-login-of-its-own)). Before the push, by Victor: the Pocket ID client (group `kubernetes_admins`, callback `https://goldilocks.shelltopia.org/oauth2/callback`) and the 1Password item. Check: a VPA per workload, its errors in the logs of the controller (owners without a scale subresource, such as the VolSync movers: `ignore-controller-kind` if needed), the dashboard after the login. Written: `rbac.enableArgoproj: false` too (no Argo Rollouts). After the check: `ignore-controller-kind: Job`, and the `VMAgent` readable by both (the only resource of an operator with a `scale` subresource).
- [x] **Docs**, with each commit: [cluster](cluster/README.md) (decisions, status, checks in [bootstrap](cluster/bootstrap.md)), [talos](../talos/README.md) if needed, [observability](observability/README.md) (the verified scrapes), [reference](reference.md) (namespace, ports, 1Password item, name), the [roadmap](roadmap.md#cluster-tools) item ticked at the end.

## 3. Sizing

Roadmap item ([roadmap](roadmap.md#cluster-tools)): the requests, the memory limits and the classes of the components already deployed, from their real usage.

### Before the sizing

- **The values today**: the [inventory](#inventory) of step 1. The tools of step 2 at estimated values.
- **VictoriaMetrics**: the usage of every container since 2026-11-03, every 30 s (cAdvisor, 90 days of retention). An init container or a Job only shows if it runs through a scrape. The bootstrap is in it: installs, restarts, the Talos applies.
- **VPA recommender**, since 2026-11-13: for each workload, a target at the 90th percentile, plus 15 %. For the CPU, of the samples of each minute; for the memory, of the peak of each day over 8 days. Half-life of 24 h. Below the peak by design, where the [convention](conventions.md#resources-and-priorities) asks for the peak plus about 20 %.
- **No VPA**: the Jobs (the hooks of the charts, the VolSync movers of Grafana), the init containers, the static pods (out of scope, the settings of Talos).
- **A usage that follows the limit**: VMSingle and VLSingle size their caches at 60 % of the memory they see, so their usage reflects their limit, not their need.
- **The heap of LINSTOR**: set by its start scripts (`build.gradle` of LINSTOR v1.35.2): `-Xms256M -Xmx8G` for the controller, `-Xms32M -Xmx2G` for the satellites, then `JAVA_OPTS` (set by the operator: `-Djdk.tls.acknowledgeCloseNotify=true`), then the variable of the script (`CONTROLLER_OPTS`, `SATELLITE_OPTS`, `LINSTOR_CONFIG_OPTS`, from Gradle). An explicit `-Xmx` wins over `MaxRAMPercentage`: a memory limit does not cap the heap, only a later `-Xmx` does. The controller on 2026-11-14: 187 MiB of heap used out of 256 MiB committed, 54 MiB left in the old generation after a collection, 136 MiB outside the heap. The satellites export no JVM metrics.
- **Shared with the bootstrap**: the helmfile reads the values of the HelmReleases of Cilium, CoreDNS, Spegel, kubelet-csr-approver, External Secrets, flux-operator and flux-instance. A change also applies at the next bootstrap.

### Queries

In Grafana, *Explore*, data source VictoriaMetrics, *Instant*, the time range on the window. *Inspect → Data → Download CSV*, into `.scratch/sizing/`. Per workload and container, the pods without a workload (the static pods) left out.

The owners, from the recording rule of the stack (kube-prometheus `k8s.rules.pod_owner`), first checked:

```promql
count by (workload_type) (namespace_workload_pod:kube_pod_owner:relabel)
```

On 2026-11-13: `deployment`, `daemonset`, `statefulset`, `job`, `CronJob`, `staticpod`, `barepod`. The `cluster` label of the series changed with the rename of the cluster (`kube-cluster01`, then `kubecluster-01`): the owners are aggregated without it, else a pod has two owners over the window.

The peak of the memory (`memory-peak.csv`):

```promql
max by (namespace, workload_type, workload, container) (
  max_over_time(container_memory_working_set_bytes{container!="", container!="POD"}[$__range])
  * on (namespace, pod) group_left (workload_type, workload)
    max by (namespace, pod, workload_type, workload) (
      max_over_time(namespace_workload_pod:kube_pod_owner:relabel[$__range])
    )
)
```

The 95th percentile of the CPU, in cores (`cpu-p95.csv`):

```promql
max by (namespace, workload_type, workload, container) (
  quantile_over_time(0.95, rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m])[$__range:5m])
  * on (namespace, pod) group_left (workload_type, workload)
    max by (namespace, pod, workload_type, workload) (
      max_over_time(namespace_workload_pod:kube_pod_owner:relabel[$__range])
    )
)
```

The recommendations and the values in the cluster:

```sh
kubectl get verticalpodautoscalers -A -l source=goldilocks -o json > .scratch/sizing/vpa.json
```

And the command of the [inventory](#from-the-cluster), into `.scratch/sizing/live.tsv`.

The reservations of Talos, per node, read-only. `MemPeak` is since the boot. `init` and `system` (the Talos services) and `podruntime` (etcd, kubelet, containerd, per the *Cgroups Resource Analysis* of Talos) against `systemReserved` (1 GiB) and `kubeReserved` (512 MiB) of `talos/patches/kubernetes.yaml.j2`, whose comment puts etcd in `systemReserved`. The static pods are in `kubepods`, with their own requests:

```sh
talosctl -n kube-01.shelltopia.net cgroups --preset=memory
talosctl -n kube-03.shelltopia.net cgroups --preset=memory
```

No history: the kubelet does not export these cgroups (the query on their `id` is empty). `MemCurrent` counts the page cache: the part that cannot be reclaimed (`anon`) is in `memory.stat`:

```sh
talosctl -n kube-01.shelltopia.net read /sys/fs/cgroup/podruntime/runtime/memory.stat
talosctl -n kube-01.shelltopia.net read /sys/fs/cgroup/podruntime/memory.stat
```

The heap of the JVM of LINSTOR, its flags and their effect:

```sh
kubectl -n piraeus-datastore exec deploy/linstor-controller -- sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < "$p/cmdline" 2>/dev/null | grep java; done'
kubectl -n piraeus-datastore exec deploy/linstor-controller -- sh -c 'java -XX:+PrintFlagsFinal -version 2>/dev/null | grep -E " (MaxHeapSize|InitialHeapSize|MaxRAMPercentage) "'
```

The same in a satellite (`ds/linstor-satellite.kube-01 -c linstor-satellite`). In Grafana, the heap used, if LINSTOR exports it: `{__name__=~"jvm_memory.*", namespace="piraeus-datastore"}`.

The OOM kills over the window (`oom.csv`, empty if none):

```promql
max by (namespace, pod, container) (
  max_over_time(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[$__range])
)
```

The VolSync movers (`movers-memory.csv`, `movers-cpu.csv`): Jobs, short, maybe missed by the scrapes. The memory peak, then the CPU peak in cores:

```promql
max by (namespace, container) (
  max_over_time(container_memory_working_set_bytes{pod=~"volsync-(src|dst)-.*", container!=""}[$__range])
)
```

```promql
max by (namespace, container) (
  max_over_time(rate(container_cpu_usage_seconds_total{pod=~"volsync-(src|dst)-.*", container!=""}[5m])[$__range:1m])
)
```

The daily peaks of the Cilium agent, in *Range* mode, *Min step* `1d`:

```promql
max by (pod) (max_over_time(container_memory_working_set_bytes{namespace="kube-system", container="cilium-agent"}[1d]))
```

### Sizing answers

1. **Now, from VictoriaMetrics.** Its history is the source; the VPA, younger, is the check. The [convention](conventions.md#resources-and-priorities) says so, in the same commit.
2. **Window**: the whole history, since 2026-11-03, bootstrap included: the peaks of a start come back at each upgrade or reboot. A peak far above the target of the VPA is read case by case (a one-off, such as the first reconciliation of the whole cluster).
3. **Formula**: memory request = peak × 1.2, limit = 2 × request; CPU request = 95th percentile. Rounded up: the CPU by 5m up to 50m, then by 10m; the memory by 16Mi up to 256Mi, by 64Mi up to 1Gi, then by 256Mi. At least 5m and 16Mi (the minimums of the VPA).
4. **VMSingle and VLSingle**: their current limits (1536Mi, 1Gi) as request and limit.
5. **LINSTOR**: the heap set by the start scripts, 8 GiB for the controller, 2 GiB for the satellites ([above](#before-the-sizing)). A `-Xmx` in the variable of the script (`CONTROLLER_OPTS`, `SATELLITE_OPTS`) in the `podTemplate`, read after `JAVA_OPTS`, which stays the one of the operator, so that the heap stays under the memory limit: `-Xmx` at the memory request, the other half of the limit for the rest of the JVM (metaspace, code, threads).
6. **Jobs and init containers**: their values in VictoriaMetrics when they show, else 10m / 32Mi, limit 128Mi. The VolSync movers: a default in `kubernetes/components/volsync`, from the peak of the movers of Grafana, to override per application later.
7. **One pass, one commit**: the table of every component at once, then applied in a `wip` commit, amended and pushed by Victor, one wave after another, with the checks after each push. Its final message at the end.
8. **The reservations of Talos** checked: the usage of `init`, `system` and `podruntime` against `systemReserved` and `kubeReserved`. Changed in Talos only if far off, then applied by Victor. Not far off: the comment only ([below](#talos-reservations)).

### Talos reservations

Read on 2026-11-13 (`talosctl cgroups --preset=memory`), kube-01 / kube-03, current (peak since the boot):

| Cgroup | kube-01 | kube-03 | Reserved by |
| --- | --- | --- | --- |
| `init` (machined) | 251 MiB (1.2 GiB) | 250 MiB (1.2 GiB) | `systemReserved` 1Gi |
| `system` (Talos services) | 213 MiB (228 MiB) | 208 MiB (214 MiB) | `systemReserved` |
| `podruntime/etcd` | 568 MiB (652 MiB) | 529 MiB (584 MiB) | `kubeReserved` 512Mi |
| `podruntime/kubelet` | 147 MiB (162 MiB) | 111 MiB (146 MiB) | `kubeReserved` |
| `podruntime/runtime` (containerd) | 4.0 GiB (4.6 GiB) | 1.1 GiB (1.1 GiB) | `kubeReserved` |
| `podruntime/shim` | 212 MiB (268 MiB) | 146 MiB (161 MiB) | `kubeReserved` |
| `kubepods` | 8.3 GiB (9.5 GiB), limit 14 GiB | 8.6 GiB (9.1 GiB), limit 14 GiB | |

- etcd is in `podruntime`, not in `systemReserved` as the comment of `talos/patches/kubernetes.yaml.j2` said.
- The kubelet only subtracts the reservations from the allocatable (it limits `kubepods` alone): their sum counts, not their split.
- `memory.stat` of kube-01: `podruntime` 583 MiB `anon` (containerd 147 MiB) and about 40 MiB of kernel memory not reclaimable; its `file` (4.2 GiB, 3.7 GiB in containerd, mostly inactive) is page cache. With `init` and `system`: about 1.1 GiB not reclaimable, for 1.5 GiB reserved.
- `kubepods/besteffort`: 2.5 GiB on kube-01, the pods without requests. They leave it with the sizing.

Decided: the reservations stay, the comment of the patch and [cluster](cluster/README.md#resources-and-priorities) fixed. A comment only: nothing to apply, `just talos diff` to confirm (no change expected).

### Sizing table

From `.scratch/sizing/` (`table.py`), the [answers](#sizing-answers) applied. Peak and p95 from VictoriaMetrics (2026-11-03 to 2026-11-14); VPA: its target on 2026-11-13; today and new: requests CPU / memory, then limits CPU / memory. The static pods and the test pods of `debug` left out.

| Namespace | Workload | Container | Peak | p95 | VPA | Today | New | Class |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `backups` | volsync | `manager` | 92Mi | 1.5m | 11m / 61Mi | 100m / 64Mi, 1 / 1Gi | 5m / 112Mi, 224Mi | `infrastructure` |
| `cert-manager` | cert-manager | `cert-manager-controller` | 92Mi | 1.5m | 11m / 47Mi | - / -, - / - | 5m / 112Mi, 224Mi | `infrastructure` |
| `cert-manager` | cert-manager-cainjector | `cert-manager-cainjector` | 118Mi | 1.9m | 11m / 89Mi | - / -, - / - | 5m / 144Mi, 288Mi | `infrastructure` |
| `cert-manager` | cert-manager-webhook | `cert-manager-webhook` | 69Mi | 0.9m | 11m / 35Mi | - / -, - / - | 5m / 96Mi, 192Mi | `infrastructure` |
| `cluster-tools` | goldilocks-controller | `goldilocks` | 32Mi | 2.8m | 11m / 35Mi | 10m / 64Mi, - / 128Mi | 5m / 48Mi, 96Mi | `infrastructure` |
| `cluster-tools` | goldilocks-dashboard | `goldilocks` | 45Mi | 0.6m | 11m / 61Mi | 10m / 64Mi, - / 128Mi | 5m / 64Mi, 128Mi | `infrastructure` |
| `cluster-tools` | kubelet-csr-approver | `kubelet-csr-approver` | 11Mi | 0.5m | 11m / 22Mi | 10m / 32Mi, - / 64Mi | 5m / 16Mi, 64Mi | `infrastructure` |
| `cluster-tools` | metrics-server | `metrics-server` | 28Mi | 4.0m | 11m / 35Mi | 10m / 64Mi, - / 128Mi | 5m / 48Mi, 96Mi | `infrastructure` |
| `cluster-tools` | vpa-recommender | `recommender` | 35Mi | 4.7m | 11m / 47Mi | 10m / 64Mi, - / 128Mi | 5m / 48Mi, 96Mi | `infrastructure` |
| `envoy-gateway-system` | envoy-gateway | `envoy-gateway` | 88Mi | 3.0m | 11m / 105Mi | 100m / 256Mi, - / 1Gi | 5m / 112Mi, 224Mi | `infrastructure` |
| `envoy-gateway-system` | envoy-network-external-b1d9befd ×2 | `envoy` | 33Mi | 5.5m | 11m / 35Mi | 100m / 512Mi, - / - | 10m / 48Mi, 96Mi | `infrastructure` |
| `envoy-gateway-system` | envoy-network-external-b1d9befd ×2 | `shutdown-manager` | 22Mi | 0.3m | 11m / 35Mi | 10m / 32Mi, - / - | 5m / 32Mi, 64Mi | `infrastructure` |
| `envoy-gateway-system` | envoy-network-internal-f0b82637 ×2 | `envoy` | 65Mi | 6.3m | 11m / 47Mi | 100m / 512Mi, - / - | 10m / 80Mi, 160Mi | `infrastructure` |
| `envoy-gateway-system` | envoy-network-internal-f0b82637 ×2 | `shutdown-manager` | 22Mi | 0.3m | 11m / 35Mi | 10m / 32Mi, - / - | 5m / 32Mi, 64Mi | `infrastructure` |
| `external-secrets` | external-secrets | `external-secrets` | 127Mi | 9.0m | 11m / 138Mi | - / -, - / - | 10m / 160Mi, 320Mi | `infrastructure` |
| `external-secrets` | external-secrets-cert-controller | `cert-controller` | 73Mi | 1.9m | 11m / 89Mi | - / -, - / - | 5m / 96Mi, 192Mi | `infrastructure` |
| `external-secrets` | external-secrets-webhook | `webhook` | 47Mi | 1.3m | 11m / 61Mi | - / -, - / - | 5m / 64Mi, 128Mi | `infrastructure` |
| `flux-system` | flux-operator | `manager` | 221Mi | 13.7m | 23m / 215Mi | 100m / 64Mi, 2 / 1Gi | 15m / 320Mi, 640Mi | `infrastructure` |
| `flux-system` | helm-controller | `manager` | 164Mi | 5.7m | 11m / 105Mi | 100m / 64Mi, 1 / 1Gi | 10m / 208Mi, 416Mi | `infrastructure` |
| `flux-system` | kustomize-controller | `manager` | 174Mi | 37.0m | 11m / 121Mi | 100m / 64Mi, 1 / 1Gi | 40m / 224Mi, 448Mi | `infrastructure` |
| `flux-system` | notification-controller | `manager` | 34Mi | 1.6m | 11m / 35Mi | 100m / 64Mi, 1 / 1Gi | 5m / 48Mi, 96Mi | `infrastructure` |
| `flux-system` | source-controller | `manager` | 117Mi | 4.9m | 11m / 61Mi | 50m / 64Mi, 1 / 1Gi | 5m / 144Mi, 288Mi | `infrastructure` |
| `kube-system` | cilium ×2 | `cilium-agent` | 640Mi | 133.0m | 126m / 335Mi | - / -, - / - | 140m / 832Mi, 1664Mi | `system-node-critical` |
| `kube-system` | cilium-envoy ×2 | `cilium-envoy` | 60Mi | 4.7m | 11m / 75Mi | - / -, - / - | 5m / 80Mi, 160Mi | `system-node-critical` |
| `kube-system` | intel-gpu-plugin-intel-gpu ×2 | `intel-gpu-plugin` | 21Mi | 0.3m | 11m / 16Mi | 40m / 45Mi, 100m / 115Mi | unchanged (set by its operator) | - (set by its operator) |
| `kube-system` | spegel ×2 | `registry` | 63Mi | 5.8m | 11m / 75Mi | 10m / 128Mi, - / 128Mi | 10m / 80Mi, 160Mi | `infrastructure` |
| `kube-system` | cilium-operator ×2 | `cilium-operator` | 175Mi | 10.5m | 11m / 105Mi | - / -, - / - | 15m / 224Mi, 448Mi | `system-cluster-critical` |
| `kube-system` | coredns ×2 | `coredns` | 52Mi | 3.1m | 11m / 61Mi | 100m / 128Mi, 100m / 128Mi | 5m / 64Mi, 128Mi | `system-cluster-critical` |
| `kube-system` | hubble-relay | `hubble-relay` | 32Mi | 2.1m | 11m / 35Mi | - / -, - / - | 5m / 48Mi, 96Mi | `infrastructure` |
| `kube-system` | hubble-ui | `backend` | 125Mi | 39.8m | 49m / 156Mi | 10m / 64Mi, - / 256Mi | 40m / 160Mi, 320Mi | `infrastructure` |
| `kube-system` | hubble-ui | `frontend` | 12Mi | 0.3m | 11m / 22Mi | 10m / 16Mi, - / 64Mi | 5m / 16Mi, 64Mi | `infrastructure` |
| `kube-system` | inteldeviceplugins-controller-manager | `manager` | 25Mi | 2.1m | 11m / 35Mi | 100m / 100Mi, 100m / 120Mi | 5m / 32Mi, 64Mi | `infrastructure` |
| `kube-system` | reloader | `reloader` | 97Mi | 0.9m | 11m / 61Mi | 10m / 64Mi, - / 256Mi | 5m / 128Mi, 256Mi | `infrastructure` |
| `kube-system` | snapshot-controller ×2 | `snapshot-controller` | 65Mi | 1.2m | 11m / 22Mi | - / -, - / - | 5m / 80Mi, 160Mi | `infrastructure` |
| `network` | cloudflare-ddns | `cloudflare-ddns` | 23Mi | 0.5m | 11m / 16Mi | 5m / 16Mi, - / 64Mi | 5m / 32Mi, 64Mi | `infrastructure` |
| `network` | external-dns | `external-dns` | 131Mi | 1.6m | 11m / 47Mi | - / -, - / - | 5m / 160Mi, 320Mi | `infrastructure` |
| `network` | k8s-gateway ×2 | `k8s-gateway` | 62Mi | 1.5m | 11m / 61Mi | 100m / 128Mi, 100m / 128Mi | 5m / 80Mi, 160Mi | `infrastructure` |
| `observability` | blackbox-exporter | `blackbox-exporter` | 24Mi | 3.7m | 11m / 35Mi | 10m / 32Mi, - / 128Mi | 5m / 32Mi, 64Mi | `infrastructure` |
| `observability` | grafana | `download-dashboards` | 3Mi | - | - | - / -, - / - | 10m / 16Mi, 64Mi | `infrastructure` |
| `observability` | grafana | `grafana` | 485Mi | 91.1m | 35m / 454Mi | 50m / 256Mi, - / 512Mi | 100m / 640Mi, 1280Mi | `infrastructure` |
| `observability` | grafana | `grafana-init-sc-datasources` | 4Mi | - | - | 10m / 64Mi, - / 128Mi | 10m / 16Mi, 64Mi | `infrastructure` |
| `observability` | grafana | `grafana-sc-dashboard` | 83Mi | 25.7m | 23m / 105Mi | 10m / 64Mi, - / 128Mi | 30m / 112Mi, 224Mi | `infrastructure` |
| `observability` | mktxp | `app` | 29Mi | 6.5m | 23m / 35Mi | 10m / 64Mi, - / 128Mi | 10m / 48Mi, 96Mi | `infrastructure` |
| `observability` | nut-exporter | `app` | 10Mi | 2.6m | 11m / 22Mi | 10m / 32Mi, - / 64Mi | 5m / 16Mi, 64Mi | `infrastructure` |
| `observability` | opnsense-exporter | `app` | 14Mi | 1.8m | 11m / 22Mi | 10m / 32Mi, - / 128Mi | 5m / 32Mi, 64Mi | `infrastructure` |
| `observability` | snmp-exporter | `snmp-exporter` | 36Mi | 5.7m | 23m / 35Mi | 10m / 64Mi, - / 256Mi | 10m / 48Mi, 96Mi | `infrastructure` |
| `observability` | victoria-metrics-k8s-stack-kube-state-metrics | `kube-state-metrics` | 127Mi | 5.2m | 11m / 156Mi | 10m / 64Mi, - / 128Mi | 10m / 160Mi, 320Mi | `infrastructure` |
| `observability` | victoria-metrics-k8s-stack-victoria-metrics-operator | `operator` | 82Mi | 10.2m | 23m / 89Mi | 20m / 128Mi, - / 256Mi | 15m / 112Mi, 224Mi | `infrastructure` |
| `observability` | vlsingle-victoria-metrics-k8s-stack | `vlsingle` | 320Mi | 23.2m | 35m / 335Mi | 50m / 256Mi, - / 1Gi | 25m / 1Gi, 1Gi | `infrastructure` |
| `observability` | vmagent-victoria-metrics-k8s-stack ×2 | `config-reloader` | 21Mi | 0.9m | 11m / 22Mi | 10m / 25Mi, - / - | 5m / 32Mi, 64Mi | `infrastructure` |
| `observability` | vmagent-victoria-metrics-k8s-stack ×2 | `vmagent` | 397Mi | 85.6m | 109m / 454Mi | 50m / 256Mi, - / 512Mi | 90m / 512Mi, 1Gi | `infrastructure` |
| `observability` | vmalert-victoria-metrics-k8s-stack ×2 | `config-reloader` | 19Mi | 0.9m | 11m / 22Mi | 10m / 25Mi, - / - | 5m / 32Mi, 64Mi | `infrastructure` |
| `observability` | vmalert-victoria-metrics-k8s-stack ×2 | `vmalert` | 83Mi | 18.8m | 35m / 105Mi | 20m / 64Mi, - / 256Mi | 20m / 112Mi, 224Mi | `infrastructure` |
| `observability` | vmauth-victoria-metrics-k8s-stack-internal ×2 | `config-reloader` | 18Mi | 0.9m | 11m / 22Mi | 10m / 25Mi, - / - | 5m / 32Mi, 64Mi | `infrastructure` |
| `observability` | vmauth-victoria-metrics-k8s-stack-internal ×2 | `vmauth` | 14Mi | 14.3m | 23m / 22Mi | 10m / 32Mi, - / 128Mi | 15m / 32Mi, 64Mi | `infrastructure` |
| `observability` | vmsingle-victoria-metrics-k8s-stack | `vmsingle` | 1478Mi | 281.0m | 350m / 1751Mi | 100m / 512Mi, - / 1536Mi | 290m / 1536Mi, 1536Mi | `infrastructure` |
| `observability` | victoria-metrics-k8s-stack-sync-job | `sync-job` | 41Mi | 24.1m | - | 10m / 64Mi, - / 256Mi | 25m / 64Mi, 128Mi | - (no field) |
| `observability` | vector-aggregator ×2 | `vector` | 90Mi | 29.5m | 35m / 105Mi | 20m / 64Mi, - / 512Mi | 30m / 112Mi, 512Mi (kept) | `infrastructure` |
| `observability` | vmalertmanager-victoria-metrics-k8s-stack ×2 | `alertmanager` | 49Mi | 5.9m | 11m / 35Mi | 10m / 64Mi, - / 128Mi | 10m / 64Mi, 128Mi | `infrastructure` |
| `observability` | vmalertmanager-victoria-metrics-k8s-stack ×2 | `config-reloader` | 22Mi | 1.0m | 11m / 22Mi | 10m / 25Mi, - / - | 5m / 32Mi, 64Mi | `infrastructure` |
| `observability-agents` | vector-agent ×2 | `vector` | 153Mi | 25.8m | 35m / 175Mi | 20m / 128Mi, - / 1Gi | 30m / 192Mi, 1Gi (kept) | `infrastructure` |
| `observability-agents` | victoria-metrics-k8s-stack-prometheus-node-exporter ×2 | `node-exporter` | 31Mi | 6.8m | 11m / 47Mi | 10m / 32Mi, - / 64Mi | 10m / 48Mi, 96Mi | `infrastructure` |
| `piraeus-datastore` | ha-controller ×2 | `ha-controller` | 63Mi | 3.2m | 11m / 75Mi | - / -, - / - | 5m / 80Mi, 160Mi | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-node ×2 | `csi-livenessprobe` | 11Mi | 0.5m | 11m / 22Mi | - / -, - / - | 5m / 16Mi, 64Mi | `system-node-critical` |
| `piraeus-datastore` | linstor-csi-node ×2 | `csi-node-driver-registrar` | 14Mi | 0.6m | 11m / 22Mi | - / -, - / - | 5m / 32Mi, 64Mi | `system-node-critical` |
| `piraeus-datastore` | linstor-csi-node ×2 | `linstor-csi` | 10Mi | 0.5m | 11m / 22Mi | - / -, - / - | 5m / 16Mi, 64Mi | `system-node-critical` |
| `piraeus-datastore` | linstor-satellite.kube-01 | `drbd-reactor` | 8Mi | 0.0m | 11m / 11Mi | - / -, - / - | 5m / 16Mi, 64Mi | `system-node-critical` |
| `piraeus-datastore` | linstor-satellite.kube-01 | `linstor-satellite` | 331Mi | 2.3m | 11m / 363Mi | - / -, - / - | 5m / 448Mi, 896Mi, `-Xmx448m` | `system-node-critical` |
| `piraeus-datastore` | linstor-satellite.kube-03 | `drbd-reactor` | 9Mi | 0.1m | 11m / 11Mi | - / -, - / - | 5m / 16Mi, 64Mi | `system-node-critical` |
| `piraeus-datastore` | linstor-satellite.kube-03 | `linstor-satellite` | 338Mi | 3.8m | 11m / 392Mi | - / -, - / - | 5m / 448Mi, 896Mi, `-Xmx448m` | `system-node-critical` |
| `piraeus-datastore` | linstor-affinity-controller | `linstor-affinity-controller` | 24Mi | 0.7m | 11m / 35Mi | - / -, - / - | 5m / 32Mi, 64Mi | `infrastructure` |
| `piraeus-datastore` | linstor-controller | `linstor-controller` | 909Mi | 5.4m | 11m / 826Mi | - / -, - / - | 10m / 1280Mi, 2560Mi, `-Xmx1280m` | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-controller | `csi-attacher` | 15Mi | 1.3m | 11m / 22Mi | - / -, - / - | 5m / 32Mi, 64Mi | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-controller | `csi-livenessprobe` | 11Mi | 0.5m | 11m / 11Mi | - / -, - / - | 5m / 16Mi, 64Mi | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-controller | `csi-provisioner` | 20Mi | 4.5m | 11m / 22Mi | - / -, - / - | 5m / 32Mi, 64Mi | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-controller | `csi-resizer` | 15Mi | 3.1m | 11m / 22Mi | - / -, - / - | 5m / 32Mi, 64Mi | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-controller | `csi-snapshotter` | 15Mi | 1.0m | 11m / 22Mi | - / -, - / - | 5m / 32Mi, 64Mi | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-controller | `linstor-csi` | 17Mi | 0.5m | 11m / 22Mi | - / -, - / - | 5m / 32Mi, 64Mi | `system-cluster-critical` |
| `piraeus-datastore` | linstor-csi-controller | `linstor-wait-api-online` | 8Mi | - | - | - / -, - / - | 10m / 16Mi, 64Mi | `system-cluster-critical` |
| `piraeus-datastore` | piraeus-operator-controller-manager | `manager` | 72Mi | 16.5m | 35m / 75Mi | - / -, - / - | 20m / 96Mi, 192Mi | `infrastructure` |

Not in the data (shorter than a scrape), at 10m / 32Mi, limit 128Mi ([answer 6](#sizing-answers)): the init containers of Cilium, LINSTOR (`setup-lvm-configuration`, `linstor-wait-node-online`), mktxp and the VictoriaMetrics resources (`config-init`), the Jobs `startupapicheck` and `certgen`, the CronJob of Hubble. `volsync-monitor` keeps its values. The VolSync movers: [below](#sizing-questions). `run-migration` of LINSTOR: the values of the controller, `-Xmx1280m` included. It is a JVM that loads the database, killed at 128Mi on 2026-11-14. Its start script sets `-Xms32M` only.

The memory limits of Vector are kept (1Gi for the agent, 512Mi for the aggregator): they are sized for a catch-up, not for the usage ([memory of Vector](observability/evaluations.md#memory-of-vector)). Two containers take the values of another one: the init container `grafana-init-sc-datasources` those of the sidecars of Grafana (one `sidecar.resources` in the chart), 30m / 112Mi instead of 10m / 16Mi; `config-init` of the VictoriaMetrics resources their `configReloaderResources` (the operator sets them on both). The request of an init container counts only when it is above those of the pod: no change.

Totals, the replicas counted, the init containers and Jobs left out:

| Namespace | CPU requests | Memory requests | Memory limits | Memory requests today |
| --- | --- | --- | --- | --- |
| `backups` | 5m | 112Mi | 224Mi | 64Mi |
| `cert-manager` | 15m | 352Mi | 704Mi | - |
| `cluster-tools` | 25m | 224Mi | 480Mi | 288Mi |
| `envoy-gateway-system` | 65m | 496Mi | 992Mi | 2432Mi |
| `external-secrets` | 20m | 320Mi | 640Mi | - |
| `flux-system` | 75m | 944Mi | 1888Mi | 320Mi |
| `kube-system` | 430m | 3168Mi | 6368Mi | 846Mi |
| `network` | 20m | 352Mi | 704Mi | 272Mi |
| `observability` | 875m | 5680Mi | 9408Mi | 2664Mi |
| `observability-agents` | 80m | 480Mi | 2240Mi | 320Mi |
| `piraeus-datastore` | 125m | 2800Mi | 5824Mi | - |
| **Total** | **1.7 cores** | **14.6 GiB** | **28.8 GiB** | **7.0 GiB** |

What it shows:

- **14.6 GiB requested of the 28 GiB allocatable** (52 %), the static pods apart; 7 GiB today. One node alone (14 GiB) no longer holds them: accepted until kube-02 joins. The limits (28.8 GiB) go above the allocatable: a limit reserves nothing, and all the components are not at their limit at once.
- **The largest moves**: the Envoy proxies from 2.4 GiB to 0.5 GiB; LINSTOR from nothing to 2.7 GiB (the controller 1280Mi); the Cilium agents from nothing to 1.6 GiB.
- **Peaks above 1.5 times the target of the VPA**: the starts of the controllers (cert-manager, Flux, the Cilium operator, external-dns, snapshot-controller, Reloader, VolSync). Kept ([answer 2](#sizing-answers)): a few MiB each. Only the Cilium agent weighs: 640 MiB against 335 MiB, 0.8 GiB of requests over the two nodes.
- **Near their limit today**: Grafana (485 MiB of 512 MiB), VMSingle (1478 MiB of 1536 MiB, its cache).
- **OOM kills** (`oom.csv`, `talosctl dmesg`), all at the limit of their container (`CONSTRAINT_MEMCG`), none of the node: Vector on 2026-11-06 (492 MiB, a catch-up of logs during its tests, before its 1Gi), VMSingle on 2026-11-13 at 03:41 UTC (1522 MiB, its limit of 1536Mi), a `tail` on 2026-11-13 at 16:52 UTC (15 MiB, a test pod). Values kept: one-off loads, to watch at the [check](#sizing-plan).
- **Small limits**: at least 64Mi ([question 2](#sizing-questions)), for Go binaries (the CSI sidecars, kubelet-csr-approver) measured at 10 MiB to 15 MiB.

### Sizing questions

Answered on 2026-11-14:

1. **Cilium agent**: its peak, 140m / 832Mi, limit 1664Mi. A kill cuts the network of its node, and a start comes back at each upgrade. Its daily peaks (`cilium-agent.csv`) hold a single point, not enough to read.
2. **A floor for the limits**: 64Mi, the request unchanged. A limit reserves nothing; at 32Mi, a burst of a Go binary (a list, a CSI operation) kills it.
3. **VolSync movers**: 128Mi, limit 256Mi. `movers-memory.csv` and `movers-cpu.csv` hold one run of restic only (9 MiB, 1.6m), too few for its peak.

### Sizing plan

- [x] **Data.** The CSVs, `vpa.json` and `live.tsv` in `.scratch/sizing/` (Victor), the reservations and the JVM read ([queries](#queries)). Done on 2026-11-13, except the two CSVs (the rename of the cluster, queries fixed) and `memory.stat`. Done on 2026-11-14.
- [x] **Table.** Per component and container: the peak, the 95th percentile, the target of the VPA, the values today, the new requests and limit, its class, the totals per namespace and against the 28 GiB.
- [x] **Apply**, in waves of the same `wip` commit, the network and the storage first. The requests, the limits and the class of each component, with `dependsOn` `priority-classes` on its Kustomization. The class of the convention where the chart or the operator sets another: Spegel (`system-node-critical`, its section of [cluster](cluster/README.md#spegel) with it), the Flux controllers, the Piraeus operator and the affinity controller to `infrastructure`; the LINSTOR controller and the CSI controller to `system-cluster-critical`. After each push: no pod `Pending`, the requests per node (`kubectl describe node`), no OOM kill. Wave 1 (`kube-system`, `piraeus-datastore`) written on 2026-11-14. Wave 2 (`flux-system`, `envoy-gateway-system` and the Envoy proxies, `network`, `cert-manager`, `external-secrets`, `backups` and the VolSync movers) written on 2026-11-14. Wave 3 (`observability`, `observability-agents`, `cluster-tools`) written on 2026-11-14. Checked on 2026-11-14: no pod `Pending`, 16.2 GiB requested (64 % and 56 % of the nodes, the static pods included), no OOM kill after the waves. During the rollout of wave 3, `ContainerWithoutMemoryLimit` fired for the pods not yet replaced (the rule applied before them), then resolved. `ContainerOOMKilled` fired for the VMSingle pod killed on 2026-11-13: the new kube-state-metrics pod made new series, whose first value `increase` counts. Fixed with `increase_prometheus` ([observability](observability/README.md#alerting)).
- [x] **Alert** `ContainerWithoutMemoryLimit` to `warning`, with wave 3: no container is left without a limit. After the push, it must not fire (the `curl` of the [checks](cluster/bootstrap.md#resources-and-priorities)).
- [ ] **Check** two weeks later: the usage against the requests and limits, adjusted.
- [x] **Docs:** the [convention](conventions.md#resources-and-priorities) (the usage first, Goldilocks to cross-check), the status in [cluster](cluster/README.md), [observability](observability/README.md) (the resources and the alert), the item ticked in the [roadmap](roadmap.md#cluster-tools).

## 4. OIDC authentication

Roadmap item as written ([roadmap](roadmap.md#cluster-tools)). Questions and plan once step 3 is done.

- [ ] Pocket ID: the public client of `kubelogin` (PKCE), the read-only group.
- [ ] Talos: `AuthenticationConfiguration` of the API server, the `groups` claim prefixed, applied on one control plane node, then the other.
- [ ] The `ClusterRoleBinding`s of the groups, in Git.
- [ ] Workstation: `kubelogin` in `mise`, an OIDC user in the kubeconfig. Break-glass: `talosctl kubeconfig` checked.

## 5. Flux web UI and Headlamp

Roadmap items as written ([roadmap](roadmap.md#cluster-tools)). Questions and plan once step 4 is done.

- [ ] Flux web UI: OIDC in flux-operator, the `HTTPRoute` on the `internal` Gateway, the roles of the chart checked, then the links in the Flux notifications.
- [ ] Headlamp: its release with the resources and class of the convention, OIDC, the `HTTPRoute` on the `internal` Gateway, the restart rights of the default group.

## 6. Descheduler

Once kube-02 joins, as in the [roadmap](roadmap.md#cluster-tools). Listed here for its dependencies on steps 2 and 3 only.

- [ ] `RemoveFailedPods` with the `NodeShutdown` reason: the pods left `Failed` by a node shutdown ([open point](cluster/evaluations.md#open-points)). Then the open point closed.
