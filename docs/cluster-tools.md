# Cluster tools

Temporary document: the plan of the [Cluster tools](roadmap.md#cluster-tools) of the roadmap, step by step. Each step writes its decisions in its topic document and ticks its item of the roadmap in the same commit ([AGENTS.md](../AGENTS.md#do-not)). This document is deleted after the last step.

## Steps

| Step | Roadmap items | Why in this order | Status |
| --- | --- | --- | --- |
| [1](#1-resources-and-priorities) | Resources and `PriorityClass`es: the convention, the classes, the checks | The convention first: every tool deployed after it (metrics-server, VPA, Headlamp) follows it from the start. | Done |
| [2](#2-kubelet-serving-certificates-metrics-server-and-vpa) | kubelet serving certificates, metrics-server, VPA and Goldilocks | Grouped: metrics-server needs the verified kubelet certificates, the VPA recommender needs metrics-server. | In progress |
| [3](#3-sizing) | Resources and `PriorityClass`es: the sizing | From the recommendations of step 2, checked against the history of VictoriaMetrics (since 2026-11-03). | To do |
| [4](#4-oidc-authentication) | Kubernetes OIDC authentication | Before the UIs: both log in through it, and their rights are the bindings of its groups. | To do |
| [5](#5-flux-web-ui-and-headlamp) | Flux web UI, Headlamp | Grouped: same pattern (a client in the Pocket ID, an `HTTPRoute` on the `internal` Gateway, the groups of step 4). The Flux UI first: nothing to deploy. | To do |
| [6](#6-descheduler) | Descheduler, `topologySpreadConstraints` | Once kube-02 joins: it uses the requests of step 3 and metrics-server of step 2. Stays in the roadmap until then. | Waits for kube-02 |

## 1. Resources and priorities

### Today

- Nodes: 16 GiB, `systemReserved` 500m and 1 GiB, `kubeReserved` 250m and 512 MiB, `evictionHard` `memory.available: 500Mi` (`talos/patches/kubernetes.yaml.j2`): about 14 GiB allocatable per node. Two nodes until kube-02 joins.
- The pattern already used by 14 manifests (the observability tools, Hubble UI, Reloader, Spegel, cloudflare-ddns, volsync-monitor): CPU and memory requests, a memory limit, no CPU limit. Nothing says why.
- No resources in the repository, the chart defaults (to check in the renders): cert-manager, Envoy Gateway (the controller, and the proxies through the `EnvoyProxy`s), External Secrets, flux-operator and the Flux controllers, the Cilium agent, operator, Envoy and Hubble Relay, CoreDNS, the Intel device plugin, snapshot-controller, external-dns, k8s-gateway, VolSync and its movers, Piraeus (operator, controller, satellites, CSI, HA controller).
- Priorities: only CoreDNS sets one (`system-cluster-critical`). The defaults of the charts to check in the renders. The Talos static pods (API server, controller-manager, scheduler) keep the settings of Talos: etcd is a Talos service, in `systemReserved`.

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
- [x] **Checks.** The alerts `ContainerWithoutMemoryLimit` (`info` until step 3) and `ContainerOOMKilled`, in `kubernetes/apps/observability/victoria-metrics-k8s-stack/app/prometheusrule.yaml`. Their checks in [bootstrap](cluster/bootstrap.md#resources-and-priorities), done on 2026-11-13.
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
2. **Namespace**: `cluster-tools`, `restricted`, for the four tools (and later Headlamp and the descheduler). `kube-system` is exempt from Pod Security for Cilium, Spegel and the GPU plugin only: in their own namespace, Pod Security refuses a chart that turns privileged, and the same-namespace policy no longer lets an exposed UI (Goldilocks) reach Hubble Relay (every flow, no authentication) or the other pods of `kube-system`. Only the `RoleBinding` of metrics-server to `extension-apiserver-authentication-reader` stays in `kube-system` (fixed by the chart, needed by every aggregated API). Reloader and snapshot-controller may move there later, in a commit of their own.
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
- [ ] **Talos: API server.** `KubeAPIServerConfig` `extraArgs` `kubelet-certificate-authority: /system/secrets/kubernetes/kube-apiserver/ca.crt`, merged with the one of `cluster-rename.yaml` (`just talos diff`). One node, then the other. Check through each API server: `kubectl logs` and `exec` of a pod of each node.
- [ ] **metrics-server and the scrapes.** Its release, TCP 10250 from its pods in the host firewall, and the kubelet `VMNodeScrape`s of the stack verified (`kubelet.vmScrape.spec.tlsConfig.insecureSkipVerify: false`). Check: `kubectl top nodes`, the targets of `VMAgent` up.
- [ ] **VPA recommender.** Admission controller and updater disabled, checkpoints, the minimums of [decision 5](#answers), the restricted `securityContext` (none by default). Check: a test VPA in `debug` gets a recommendation.
- [ ] **Goldilocks.** Controller and dashboard (`on-by-default` on both, `enable-cost: false`, `pullPolicy: IfNotPresent`), the class by `postRenderers`. The `HTTPRoute` `goldilocks.shelltopia.org` on the `internal` Gateway, the `SecurityPolicy`, the `ExternalSecret` of `pocket-id-goldilocks` ([UI pattern](ingress/runbook.md#a-ui-without-a-login-of-its-own)). Before the push, by Victor: the Pocket ID client (group `kubernetes_admins`, callback `https://goldilocks.shelltopia.org/oauth2/callback`) and the 1Password item. Check: a VPA per workload, its errors in the logs of the controller (owners without a scale subresource, such as the VolSync movers: `ignore-controller-kind` if needed), the dashboard after the login.
- [ ] **Docs**, with each commit: [cluster](cluster/README.md) (decisions, status, checks in [bootstrap](cluster/bootstrap.md)), [talos](../talos/README.md) if needed, [observability](observability/README.md) (the verified scrapes), [reference](reference.md) (namespace, ports, 1Password item, name), the [roadmap](roadmap.md#cluster-tools) item ticked at the end.

## 3. Sizing

- [ ] **Recommendations.** Goldilocks, after 8 days of data for the VPA recommender, against the history of VictoriaMetrics (the peak of `container_memory_working_set_bytes`, the 95th percentile of the CPU), so that the nightly backups and the reconciliations are in it. The queries kept here.
- [ ] **Apply**, one namespace per commit, the network and the storage first. The requests, the limits and the class of each component, with `dependsOn` `priority-classes` on its Kustomization. The class of the convention where the chart or the operator sets another: Spegel (`system-node-critical`, its section of [cluster](cluster/README.md#spegel) with it), the Flux controllers, the Piraeus operator and the affinity controller to `infrastructure`; the LINSTOR controller and the CSI controller to `system-cluster-critical`. After each push: no pod `Pending`, the requests per node (`kubectl describe node`), no OOM kill.
- [ ] **Alert** `ContainerWithoutMemoryLimit` to `warning`, once it no longer fires.
- [ ] **Check** two weeks later: the usage against the requests and limits, adjusted.
- [ ] **Docs:** the status in [cluster](cluster/README.md), the item ticked in the [roadmap](roadmap.md#cluster-tools).

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
