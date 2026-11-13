# Roadmap

What is left to build on the Kubernetes cluster, and the questions still open. The decisions already made are in the `README.md` of each [topic](README.md#topics). The manual steps of the first bootstrap are in [first-bootstrap.md](first-bootstrap.md).

## Current state

| Area | Status |
| --- | --- |
| Talos machine configs (`talos/`) | Done: Secure Boot, TPM disk encryption, disks and NIC selectors, dynamic network, NTP, NUT, watchdog, i915, DRBD, image verification. Pod Security `restricted` by default, not applied yet ([checks](cluster/bootstrap.md#pod-security)). |
| Bootstrap (`bootstrap/`, `just bootstrap cluster`) | Done: Cilium (+ BGP and LB pools), CoreDNS, External Secrets, Flux. Spegel added, not run yet. |
| GitOps (`kubernetes/apps`) | In use: Flux, External Secrets, Cilium, CoreDNS, cert-manager, Envoy Gateway and the Gateways, the application DNS, the storage, the backups and Reloader. Spegel added, [checks](cluster/bootstrap.md#spegel) not run yet. Cilium network policies enforced. The status of each is in its [topic](README.md#list). |
| OpenTofu (`tofu/`) | States in B2 (encrypted, no locking). `backblaze`: buckets and keys of the backups, applied, keys pushed to 1Password. `cloudflare`: records not managed from the cluster (mail, CAA, PikaPods), SSL settings and DNSSEC, applied. |
| First bootstrap | In progress, with kube-01 and kube-03 only. |

## Order of work

The sections of [To implement](#to-implement) are by topic, in the order they are first needed. What is done is tracked in the status of each topic, and the detail of each step in its `bootstrap.md`: only what is left is listed here.

1. **Platform, before the applications move.** Everything that is cheap to do on an empty cluster and painful to retrofit on 30 applications:
   - [Observability](#observability): metrics, Flux notifications, alerting, logs.
   - [Security](#security): network policies enforced.
   - [Cluster tools](#cluster-tools): resource and priority conventions, kubelet certificates and metrics-server, Headlamp, the Flux web UI and OIDC.
   - [Backups](#backups): NAS data (independent of the cluster, can be done at any time) and PostgreSQL.
   - [Storage](#storage): NFS access to the NAS.
   - [PostgreSQL](#postgresql): CloudNativePG, before the applications that have a database.
2. **[Migration](#migration).** `home` first (it becomes kube-02, and the 2-node etcd has no fault tolerance until then), then the Hetzner VM.
3. **After kube-02 joins.** The items marked *once kube-02 joins*: [Storage](#storage) and [Backups](#backups) tests, the end of the [Ingress](#ingress) migration, the descheduler, and the whole of [Upgrades](#upgrades) (PDBs, power outage test, Renovate, tuppr), then the first Talos upgrades.
4. **Later.** [Kubernetes recipes](#kubernetes-recipes) and [Remote node management](#remote-node-management).

## To implement

### Observability

Architecture and status: [observability/README.md](observability/README.md#status), the stages in [observability/bootstrap.md](observability/bootstrap.md). The stack: `victoria-metrics-k8s-stack` (operator, `VMSingle`, `VLSingle`, `VMAgent`, `VMAlert`, `VMAlertmanager`, kube-state-metrics, node-exporter, default rules and dashboards), Grafana as its own release, Vector for all the logs, Alertmanager to Pushover. Grafana logs in through the Pocket ID only, no local account. Order: Alertmanager and the Flux notifications, then the metrics, then the logs (before enforcing the network policies), the rules and the dead man's switch, and the external devices.

- [x] Alertmanager and Flux notifications ([stage 1](observability/bootstrap.md#1-operator-alertmanager-flux-notifications)): the release of the stack with the operator and the `VMAlertmanager` only (two replicas, Pushover the only channel, `critical` priority 1, `warning` priority 0, `info` dropped). Flux: a `Provider` of type `alertmanager` and an `Alert` of the notification controller for the failed reconciliations, in every namespace (component `flux-alerts`); it has no Pushover provider, and its events have no end time, hence `resolve_timeout: 1h`. Replaced at stage 4 by rules on the metrics of the flux-operator ([alerting](observability/README.md#alerting)): the component, its network policy and `resolve_timeout` removed.
- [x] Metrics ([stage 2](observability/bootstrap.md#2-metrics)), written, not deployed: `prometheus-operator-crds` (Flux application and bootstrap CRDs, `just bootstrap crds` before the push), then in the stack `VMSingle` (50 Gi, 90 days), `VMAgent` (two replicas), kube-state-metrics, node-exporter, the control plane scrapes (etcd `:2381` by a `VMNodeScrape`, scheduler and controller-manager bound to `0.0.0.0`), and the Grafana release. Network policies: the scraper to every pod in `kubernetes/apps/kube-system/cilium/policies/baseline.yaml`, and to the node ports it scrapes in `host.yaml`.
  - The monitors already prepared enabled: cert-manager, External Secrets, flux-operator, Spegel, Reloader, external-dns, k8s-gateway.
  - The others added: Cilium agent, Cilium operator and Hubble, CoreDNS, a `PodMonitor` for the Flux controllers, Piraeus (LINSTOR, drbd-reactor), VolSync, Envoy Gateway.
  - The Hubble metrics (`drop` and `policy`, with `sourceContext` and `destinationContext` set to `workload-name|app|reserved-identity`), and the dashboard of the denied flows.
- [x] Logs ([stage 3](observability/bootstrap.md#3-logs)): `VLSingle` (30 Gi, 30 days), Vector (an agent on each node and a two-replica aggregator for the syslog of the devices), and the Talos service and kernel logs sent over TCP (`machine.logging` / `KmsgLogConfig`) to the agent of the node, through its hostPorts on `127.0.0.1`. The agent also ships the denied flows exported by Hubble (`/var/run/cilium/hubble/events*.log` on each node, JSON lines, [cluster](cluster/README.md#network-policies)), so that they can be searched by namespace before and after the network policies are enforced.
- [x] Rules and dead man's switch ([stage 4](observability/bootstrap.md#4-alert-rules-and-the-dead-mans-switch)): `VMAlert` (two replicas) with the default rules of the stack, the mixins of cert-manager, CoreDNS and Cilium (fetched by the sync-job of the stack), the upstream rules of Piraeus (`config/extras/monitoring/alerts.yaml` of the operator, at the tag of the chart: DRBD and LINSTOR resources, the thin pool), and rules for the failures specific to this cluster: certificates close to expiry (a `critical` on top of the mixin), `volsync_volume_out_of_sync` and late or paused backups ([backups](backups/README.md#monitoring)), Flux resources not `Ready` (`flux_resource_info` of the flux-operator, pushed with 4a), the LINSTOR thin pool filling up (a `critical` on top of the upstream rule), flows denied by the network policies (the Hubble verdicts only, `hubble_policy_verdicts_total` with `action="audit"` while in audit mode, then `action="dropped"`; no `hubble_drop_total`, which has no namespace), errors of Vector, and the SELinux denials on unlabeled volumes (LogsQL). The `Watchdog` alert pinged to healthchecks.io every minute, so that a silent Alertmanager is noticed.
- [ ] Two weeks after stage 4: the noise-tuning pass of the alerts ([open points](observability/evaluations.md#open-points)), and the volume sizes checked against the growth. Then remove `volsync-monitor` and its healthchecks.io check, replaced by the VolSync alerts ([backups](backups/README.md#monitoring)).
- [x] External devices ([stage 5](observability/bootstrap.md#5-external-devices), [README](observability/README.md#external-devices), [points to verify](observability/evaluations.md#to-verify)): metrics and logs of OPNsense, the MikroTik switch and the Grandstream access point, the syslog of the NAS, the UPS (`nut_exporter`, MKTXP, `os-node_exporter` and `opnsense-exporter`, `snmp_exporter` for the access point, syslog), and HTTP checks of Uptime Kuma and Pocket ID (hosted at PikaPods). The scrapers with egress policies by FQDN. The NAS metrics come with the NAS platform work ([Backups](#backups)), `gw-01` with the LTE backup.
- [ ] Once kube-02 joins: enable `KubeCPUOvercommit` and `KubeMemoryOvercommit` again, and test the loss of a node holding `VMSingle` or `VLSingle` (no gap in the data, Grafana back in a few minutes).

### Security

The plan, its decisions and its steps: [hubble-security.md](hubble-security.md).

- [x] Cilium network policies: enforced on 2026-11-13 (`policyAuditMode: false`), once the audited flows were read and the [observability](#observability) stack showed the drops, then [checked](cluster/bootstrap.md#network-policies). The host firewall, the baseline of the pods, the exceptions and Hubble Relay are deployed ([cluster](cluster/README.md#network-policies)).
- [x] Hubble UI, as `hubble.shelltopia.org` on the `internal` Gateway, behind a login on the Pocket ID done by Envoy (Relay and the `hubble` CLI are in place). Deployed on 2026-11-13 ([cluster](cluster/README.md#network-policies)).

### Cluster tools

- [ ] Resource requests and limits on every workload, and `PriorityClass`es so that the storage (LINSTOR, DRBD) and network (Cilium, CoreDNS, Envoy) components win against the applications under memory pressure. Nodes have 16 GiB with `systemReserved` and `kubeReserved` already set. Write the convention in [conventions.md](conventions.md) first, then size the requests from the real usage once the metrics stack runs (a VPA in recommendation mode or Goldilocks can help).
- [ ] kubelet serving certificates and metrics-server. The kubelets use self-signed serving certificates (no `serverTLSBootstrap` in `KubeletConfig`), which nothing verifies today.
  - Set `serverTLSBootstrap: true` in `KubeletConfig` and deploy `kubelet-serving-cert-approver`, otherwise the serving CSRs stay `Pending`. Deploy the approver first, then change the Talos config, so that no node is left without a valid certificate.
  - Deploy metrics-server (`kubectl top`, resource usage in Headlamp, and the real utilization for the descheduler). It is not a source for the monitoring stack: that one scrapes the kubelet `/metrics/resource` endpoint and cAdvisor itself, with the verified TLS. It needs the kubelet port TCP 10250 from its pods in `kubernetes/apps/kube-system/cilium/policies/host.yaml`.
  - Can wait for the metrics stack and be done together.
- [ ] Web UI to view the cluster, with simple actions (restart a workload, look at logs and events): Headlamp (kubernetes-sigs), chosen. Flux has its own UI (next item), so no Flux plugin.
  - Why: general purpose, plugins, native OIDC login, and the actions follow the RBAC of the logged-in user, so the pod itself needs no rights.
  - Not chosen: Kubernetes Dashboard (retired, repository archived in `kubernetes-retired` in January 2026), Rancher and Portainer (much heavier than needed).
  - Exposure: `internal` Gateway only, never on the external one. Login with OIDC (see below): no basic authentication, no static token.
  - RBAC: bind the OIDC groups, not users (see below). The default group is read-only (`view` plus the logs and events), the restarts need `patch` on Deployments, StatefulSets and DaemonSets. Nobody logs in as `cluster-admin` from the UI.
- [ ] Flux web UI: the Flux Status web interface of flux-operator, already running in the operator pod (`web.enabled`, chart default), to follow the Kustomizations and HelmReleases and reconcile, suspend or resume them.
  - Why: made for Flux (dependencies, history, sources), shipped with the operator, nothing more to deploy. Rather than the Flux plugin of Headlamp.
  - Exposure: an `HTTPRoute` on the `internal` Gateway to the `flux-operator` Service (web port 9080, to check in the chart). No network policy to add: the baseline already lets the Gateways reach every pod. Never on the external Gateway.
  - Login with OIDC on the Pocket ID (see below), configured in flux-operator. The actions impersonate the logged-in user and its groups (`web.userActions.access: Impersonated`, the default), so the `ClusterRoleBinding`s of the OIDC groups apply: the reconcile, suspend and resume need `patch` on the Flux resources. Check the roles the chart creates (`web.rbac.createRoles`).
  - Links in the Flux notifications: the page of each object of `FluxResourceNotReady` (`/resource/<kind>/<namespace>/<name>`: the full message, the events, the source and the managed objects), for the details the summary does not hold ([alerting](observability/README.md#alerting)). Pushover takes one URL per notification, which groups several objects: keep Grafana in `url` and put one link per object in the body (`html` of `pushover_configs`, to check in the Alertmanager version), or link the filtered list (`/resources?namespace=<namespace>&status=Failed`, to check that the filters load from the URL). Only reachable where the `internal` Gateway is.
- [ ] Kubernetes OIDC authentication with the Pocket ID (hosted on PikaPods), for `kubectl`, Headlamp and the Flux web UI.
  - Gain: no long-lived `cluster-admin` client certificate on the workstation (the one from `talosctl kubeconfig` is valid one year), and rights by group.
  - Pocket ID: one OIDC client with PKCE (public client for `kubelogin`), and one for each UI (Headlamp, Flux), or fewer if the audiences are shared. The first one is Grafana's, confidential, with the groups `grafana_admins` and `grafana_viewers` ([observability](observability/README.md#grafana)), then Hubble UI's, confidential, used by Envoy ([cluster](cluster/README.md#network-policies)). Groups sent in the `groups` claim: `kubernetes_admins` for the administrators of Kubernetes, already used by Hubble UI ([plan](hubble-security.md#decisions)), and a read-only group to name with Headlamp. Callback URLs of the UIs on the `internal` Gateway.
  - Talos: `AuthenticationConfiguration` of the kube-apiserver (several audiences and claim mappings, better than the `--oidc-*` flags) through the `cluster.apiServer` patch. Issuer URL of the Pocket ID, with the `groups` claim prefixed (for example `oidc:`) so that a group name cannot collide with a Kubernetes one. Restart and test on one control plane node before the other.
  - Workstation: `kubelogin` (`kubectl oidc-login`) in `mise`, a dedicated user in the kubeconfig, the `just` recipes unchanged.
  - `ClusterRoleBinding`s of the groups, in Git.
  - Break-glass: the Talos admin kubeconfig (`talosctl kubeconfig`) stays valid and must keep working. The apiserver only needs the Pocket ID when someone authenticates, not to start, but with PikaPods down no OIDC login is possible. Never bind a resource the cluster itself needs (Flux, ESO) to an OIDC identity.
- [ ] Once kube-02 joins: descheduler and `topologySpreadConstraints`: spread the replicas of an application over the nodes, and rebalance the pods after a node comes back (reboot, upgrade, kube-02 joining). To be coherent with the LINSTOR volumes (the pod should follow a replica) and the `ImageLocality` choice of Spegel.

### Backups

Architecture and status: [backups/README.md](backups/README.md#status). Order: volumes, NAS data.

- [ ] NAS data: Backrest App on TrueNAS ([checklist](backups/bootstrap.md#3-nas-data-backrest)), then stop autorestic and delete the old buckets. Independent of the cluster, can be done at any time.
- [ ] PostgreSQL: Barman Cloud plugin of CloudNativePG, implemented with CNPG, before the applications that have a database. Network policies: the operator and the plugin reach the instances in the namespaces of the applications, which needs an exception for them (in the baseline or per cluster).
- [ ] The bucket rebuild at a past date, on a new throwaway bucket ([procedure](backups/runbook.md#recovery-after-a-deletion-of-the-backups), [open point](backups/evaluations.md#open-points)).
- [ ] Once kube-02 joins: the [node down test](backups/bootstrap.md#2-test-volsync) of VolSync.
- [ ] Once applications use VolSync: automated restore tests in a throwaway namespace.
- [ ] Once applications use VolSync: monitor the content of the repositories: the healthchecks checks watch the jobs, not the repositories, so a malicious `forget` would go unnoticed. Check the number and age of the snapshots of each repository, compared with the previous run.

### Storage

- [ ] NFS access to the NAS, through static PersistentVolumes ([runbook](storage/runbook.md#mounting-a-nas-share)): the exports must allow the nodes subnet, then the [read-ahead check](nodes/runbook.md#checking-the-nfs-read-ahead).
- [ ] NFS access to the NAS, through truenas-csi or democratic-csi for the storage of Nextcloud and Immich.
- [ ] Once kube-02 joins: the tie-breakers of the existing volumes, then the [failover test](storage/bootstrap.md#3-failover-test) ([status](storage/README.md#status)).

### PostgreSQL

- [ ] A PostgreSQL cluster with CloudNativePG, before the applications that have a database: the operator, then the cluster, with its backups ([Barman Cloud plugin](#backups)). To decide first: one cluster shared by the applications or one per application, the number of instances, and the storage class (`local`, CloudNativePG replicating itself). Its metrics and alerts as for the other components ([alerting](observability/README.md#alerting)).

### Migration

- [ ] Move the services of `home`, then turn it into kube-02 ([procedure](nodes/runbook.md#adding-kube-02)). Until then, the 2-node etcd has no fault tolerance. For each migrated name: HAProxy rules to the external Gateway and DNS records ([ingress/runbook.md](ingress/runbook.md#migrating-a-name-from-home)). Per-route needs: basic authentication (`SecurityPolicy` on the route), Plex over HTTPS to its backend (or *Secure connections: Preferred*).
- [ ] Move the services of the Hetzner VM, then delete the VM.
- [ ] For each application, [Pod Security](cluster/README.md#pod-security) `restricted` ([conventions](conventions.md#pod-security)): an image that runs as non-root, its UID and GID in the manifest, its data `chown`ed to them when copied to its volume (the Podman containers ran as root), the NAS shares through static PersistentVolumes. Otherwise a namespace at `baseline`, with the reason in a comment.
- [ ] Evaluate user namespaces (`hostUsers: false`) per application: root in the container is mapped to an unprivileged UID of the node, so an image that starts as root could stay as is ([cluster](cluster/README.md#pod-security)). First test a real pod with a LINSTOR volume ([open point](cluster/evaluations.md#open-points)). Not for the pods that mount a NAS share (no idmapped mounts on NFS) nor the `hostNetwork` ones; the s6-overlay and linuxserver.io images still need `baseline` (capabilities `CHOWN`, `SETUID`, `SETGID`).
- [ ] Replace calibre (KasmVNC) with another application.
- [ ] For each migrated service, decide whether it must keep running or be stopped (KEDA scale to 0) or cut off from the Internet (Cilium `egressDeny`) while the cluster runs on the LTE backup, and label it accordingly ([lte-backup.md](network/lte-backup.md#workloads-during-a-failover)). Plex and the other stateful applications that must not stay reachable are stopped.
- [ ] Rewrite `README.md` once Ansible is gone (it still describes the Fedora CoreOS setup).

### Ingress

- [ ] Pin the addresses of the Envoy Services of both Gateways (`lbipam.cilium.io/ips`, [conventions](conventions.md#loadbalancer-addresses)) to the ones they have today, checked first: `.1` of the `internal` pool, the first address of the `external` pool. Before the receivers of the observability stack take their pinned addresses.
- [ ] Once `home` is migrated (see [Migration](#migration)): IPv4 port forwarding 80/443 to the external Gateway instead of HAProxy, and removal of the PROXY protocol listeners ([procedure](ingress/runbook.md#removing-haproxy)).

### Upgrades

All of it waits for kube-02: rebooting one of the two etcd members loses the quorum for the duration of the reboot, and the PDB and DRBD checks need three nodes to mean anything. Until then, the upgrades stay manual (`just talos upgrade-node` / `upgrade-k8s`).

- [ ] `PodDisruptionBudget`s for the components that must not go down together during a drain (Envoy Gateway, CoreDNS, the LINSTOR controller, CloudNativePG clusters), and the drain order with DRBD: a node must not be drained or rebooted while the resources it holds are not `UpToDate` on the others. Test a manual Talos upgrade with it before automating.
- [ ] Test the [power outage](nodes/runbook.md#power-outage) path end to end: NUT shutdown, then restart of the three nodes (TPM unlock, DRBD resynchronization, Flux catching up).
- [ ] Deploy Renovate in the cluster (GitHub token through ESO). Automerge of the minor and patch updates, except the minors of Cilium, Envoy Gateway, Piraeus and Flux (their patches only): their minors can change the network, the storage or the deployments, including what the network policies rely on. No automerge at all for `victoria-metrics-k8s-stack` (0.x, breaking changes between versions, [observability](observability/evaluations.md#victoria-metrics-k8s-stack-or-separate-releases)).
- [ ] Decide where the Talos and Kubernetes versions live ([open decisions](#open-decisions)) and update `.renovaterc.json5`: its package rules still describe manual upgrades with `just talos upgrade-node` / `upgrade-k8s`.
- [ ] Deploy tuppr in `system-upgrade` (Talos API access already allowed for this namespace, role `os:admin`), with the PDBs and the DRBD check above in place. Network policies: TCP 50000 from its pods in `kubernetes/apps/kube-system/cilium/policies/host.yaml`.

### Kubernetes recipes

- [ ] The planned `just kube` recipes, ideas taken from [onedr0p/home-ops](https://github.com/onedr0p/home-ops/blob/main/kubernetes/mod.just) ([list](cluster/runbook.md#the-just-kube-recipes)).

### Remote node management

- [ ] Study a way to power cycle a node remotely and, ideally, to see its console without a working OS (Intel AMT, smart plug, PiKVM-like device): [nodes/evaluations.md](nodes/evaluations.md#remote-node-management).

## Open decisions

| Topic | Options | Notes |
| --- | --- | --- |
| Talos/Kubernetes version source | `talos/vars.yaml` (+ mise) or tuppr resources | Renovate should bump both in the same PR, or one should reference the other. |
| Renovate in the cluster | Renovate operator, plain CronJob | GitHub App or fine-grained token. |
| Cluster endpoint | DNS round-robin (current) | `kubectl` may wait for a timeout when a node is down. A VIP would need a fixed address in the nodes subnet, against the "dynamic" rule of the network. |

## To check or watch

The points of each topic are kept in its `evaluations.md`.

- [ ] Network: ECMP and multi-WAN on OPNsense, the NAS *Pre Init* script, the ISP prefix change, the Milkywan WireGuard tunnel (in place, left: DNS), Cilium `bpf.masquerade`: [network/evaluations.md](network/evaluations.md#open-points).
- [ ] Nodes: watchdog, `nfsrahead`, Talos firmware updates, firmware reset to the factory Secure Boot keys, serial of SATA disks, `EthernetConfig` alias, TPM unlock failure seen once on kube-01, Dell *Microsoft UEFI CA*, reboot of kube-03 stuck on `error closing encrypted volume` (`r-storage`): [nodes/evaluations.md](nodes/evaluations.md#open-points).
- [ ] Cluster: Intel DRA driver, network policies (Talos host DNS), drops seen by Hubble without a verdict of the policies (`UNKNOWN_L3_TARGET_ADDRESS` at the deployments, `FORBIDDEN_ICMPV6_MESSAGE` from `kube-apiserver`): [cluster/evaluations.md](cluster/evaluations.md#open-points).
- [ ] Storage: LINSTOR thin pool oversubscription, Talos and the LINSTOR VG, Piraeus `talos-loader-override`, restarts of the LINSTOR controller (lost lease, `linstorControllerOffline`): [storage/evaluations.md](storage/evaluations.md#open-points).
- [ ] Ingress: Envoy Gateway listeners after an upgrade (`ecdhCurves`): [ingress/evaluations.md](ingress/evaluations.md#open-points).
- [ ] Backups: Kopiur, to look at again in early 2027 ([checklist](backups/evaluations.md#kopiur-evaluated-to-revisit)).
- [ ] Token expirations: Docker Hub, GitHub (Flux, Renovate), Cloudflare (cert-manager, external-dns, cloudflare-ddns, OpenTofu), see the [tokens to renew](secrets/runbook.md#tokens-to-renew).
- [ ] Workstation 1Password service account: rotate its token every 30 days (`opsa` warns 5 days before and refuses to run past the limit), see [secrets/runbook.md](secrets/runbook.md#rotating-the-workstation-token).
