# Roadmap

What is left to build on the Kubernetes cluster, and the questions still open. The decisions already made are in the `README.md` of each [topic](README.md#topics). The manual steps of the first bootstrap are in [first-bootstrap.md](first-bootstrap.md).

## Current state

| Area | Status |
| --- | --- |
| Talos machine configs (`talos/`) | Done: Secure Boot, TPM disk encryption, disks and NIC selectors, dynamic network, NTP, NUT, watchdog, i915, DRBD, image verification. |
| Bootstrap (`bootstrap/`, `just bootstrap cluster`) | Done: Cilium (+ BGP and LB pools), CoreDNS, External Secrets, Flux. Spegel added, not run yet. |
| GitOps (`kubernetes/apps`) | In use: Flux, External Secrets, Cilium, CoreDNS, cert-manager, Envoy Gateway and the Gateways, the application DNS, the storage, the backups and Reloader. Spegel added, [checks](cluster/bootstrap.md#spegel) not run yet. Cilium network policies deployed in audit mode. The status of each is in its [topic](README.md#list). |
| OpenTofu (`tofu/`) | States in B2 (encrypted, no locking). `backblaze`: buckets and keys of the backups, applied, keys pushed to 1Password. `cloudflare`: records not managed from the cluster (mail, CAA, PikaPods), SSL settings and DNSSEC, applied. |
| First bootstrap | In progress, with kube-01 and kube-03 only. |

## Order of work

The sections of [To implement](#to-implement) are by topic, in the order they are first needed. What is done is tracked in the status of each topic, and the detail of each step in its `bootstrap.md`: only what is left is listed here.

1. **Platform, before the applications move.** Everything that is cheap to do on an empty cluster and painful to retrofit on 30 applications:
   - [Observability](#observability): metrics, Flux notifications, alerting, logs.
   - [Security](#security): network policies enforced, Pod Security Admission.
   - [Cluster tools](#cluster-tools): resource and priority conventions, kubelet certificates and metrics-server, Headlamp, the Flux web UI and OIDC.
   - [Backups](#backups): NAS data (independent of the cluster, can be done at any time) and PostgreSQL.
   - [Storage](#storage): NFS access to the NAS.
2. **[Migration](#migration).** `home` first (it becomes kube-02, and the 2-node etcd has no fault tolerance until then), then the Hetzner VM.
3. **After kube-02 joins.** The items marked *once kube-02 joins*: [Storage](#storage) and [Backups](#backups) tests, the end of the [Ingress](#ingress) migration, the descheduler, and the whole of [Upgrades](#upgrades) (PDBs, power outage test, Renovate, tuppr), then the first Talos upgrades.
4. **Later.** [Kubernetes recipes](#kubernetes-recipes) and [Remote node management](#remote-node-management).

## To implement

### Observability

- [ ] Metrics stack, then enable the `ServiceMonitor`/`PodMonitor` already prepared: Cilium, Cilium operator, CoreDNS, cert-manager, External Secrets, Flux, Spegel. Control plane metrics are already exposed (etcd `:2381`, scheduler and controller-manager bound to `0.0.0.0`). Network policies: allow the scraper to every pod in `kubernetes/apps/kube-system/cilium/policies/baseline.yaml`, and to the node ports it scrapes in `host.yaml` (kubelet 10250, etcd 2381, scheduler 10259, controller-manager 10257, the Cilium agent and operator, Hubble 9965, drbd-reactor 9942, node-exporter); enable the Hubble metrics (`hubble.metrics.enabled`: `drop` and `policy`, with `sourceContext` and `destinationContext` set to `workload-name|reserved-identity`), and a dashboard of the denied flows.
- [ ] Flux notifications: a `Provider` and an `Alert` of the notification controller for the failed reconciliations (same channel as the alerting below). It does not need the metrics stack and can be done before it.
- [ ] Alerting: Alertmanager and a notification channel (Pushover), with a dead man's switch (an always firing alert pinged to healthchecks.io, so that a silent Alertmanager is noticed). Rules for the failures specific to this cluster: certificates close to expiry, `volsync_volume_out_of_sync` and missing or failed snapshots ([backups](backups/README.md#status)), DRBD and LINSTOR resources not `UpToDate`, Flux resources not `Ready`, LINSTOR thin pool or node disks filling up, flows dropped by the network policies (`hubble_drop_total` with the reason `POLICY_DENIED`, from the Hubble metrics). The healthchecks.io checks of the backups may then be dropped.
- [ ] Logs: VictoriaLogs or Loki, a collector in the cluster, and the Talos service and kernel logs sent to it (`machine.logging` / `KmsgLogConfig`) through an FQDN. Network policies: the receiver of the Talos logs needs an exception from `remote-node`. The collector also ships the denied flows exported by Hubble (`/var/run/cilium/hubble/events*.log` on each node, JSON lines, [cluster](cluster/README.md#network-policies)), so that they can be searched by namespace before and after the network policies are enforced.

### Security

- [ ] Cilium network policies: enforce them once the [observability](#observability) stack runs (the denied flows in the logs, the alert on the drops). Until then, they stay in audit mode: run the [checks](cluster/bootstrap.md#network-policies) and read the audited flows (exported on each node, then in the logs), then set `policyAuditMode: false`. The host firewall, the baseline of the pods, the exceptions and Hubble Relay are deployed ([cluster](cluster/README.md#network-policies)).
- [ ] Pod Security Admission: Talos enforces `baseline` on every namespace by default (and `restricted` for audit and warn). Set `pod-security.kubernetes.io/enforce: restricted` on the namespaces of the applications that support it, keep the exceptions explicit (`piraeus-datastore` is `privileged`), and add the labels to the conventions ([namespaces](conventions.md#namespaces)).
- [ ] Optional: Hubble UI, on the `internal` Gateway (Relay and the `hubble` CLI are in place).

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
- [ ] Kubernetes OIDC authentication with the Pocket ID (hosted on PikaPods), for `kubectl`, Headlamp and the Flux web UI.
  - Gain: no long-lived `cluster-admin` client certificate on the workstation (the one from `talosctl kubeconfig` is valid one year), and rights by group.
  - Pocket ID: one OIDC client with PKCE (public client for `kubelogin`), and one for each UI (Headlamp, Flux), or fewer if the audiences are shared. Groups sent in the `groups` claim, for example `kube-admin` and `kube-viewer`. Callback URLs of the UIs on the `internal` Gateway.
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

- [ ] NFS access to the NAS: the exports must allow the nodes subnet, then the [read-ahead check](nodes/runbook.md#checking-the-nfs-read-ahead).
- [ ] Once kube-02 joins: the tie-breakers of the existing volumes, then the [failover test](storage/bootstrap.md#3-failover-test) ([status](storage/README.md#status)).

### Migration

- [ ] Move the services of `home`, then turn it into kube-02 ([procedure](nodes/runbook.md#adding-kube-02)). Until then, the 2-node etcd has no fault tolerance. For each migrated name: HAProxy rules to the external Gateway and DNS records ([ingress/runbook.md](ingress/runbook.md#migrating-a-name-from-home)). Per-route needs: basic authentication (`SecurityPolicy` on the route), Plex over HTTPS to its backend (or *Secure connections: Preferred*).
- [ ] Move the services of the Hetzner VM, then delete the VM.
- [ ] Replace calibre (KasmVNC) with another application.
- [ ] Rewrite `README.md` once Ansible is gone (it still describes the Fedora CoreOS setup).

### Ingress

- [ ] Once `home` is migrated (see [Migration](#migration)): IPv4 port forwarding 80/443 to the external Gateway instead of HAProxy, and removal of the PROXY protocol listeners ([procedure](ingress/runbook.md#removing-haproxy)).

### Upgrades

All of it waits for kube-02: rebooting one of the two etcd members loses the quorum for the duration of the reboot, and the PDB and DRBD checks need three nodes to mean anything. Until then, the upgrades stay manual (`just talos upgrade-node` / `upgrade-k8s`).

- [ ] `PodDisruptionBudget`s for the components that must not go down together during a drain (Envoy Gateway, CoreDNS, the LINSTOR controller, CloudNativePG clusters), and the drain order with DRBD: a node must not be drained or rebooted while the resources it holds are not `UpToDate` on the others. Test a manual Talos upgrade with it before automating.
- [ ] Test the [power outage](nodes/runbook.md#power-outage) path end to end: NUT shutdown, then restart of the three nodes (TPM unlock, DRBD resynchronization, Flux catching up).
- [ ] Deploy Renovate in the cluster (GitHub token through ESO). Automerge of the minor and patch updates, except the minors of Cilium, Envoy Gateway, Piraeus and Flux (their patches only): their minors can change the network, the storage or the deployments, including what the network policies rely on.
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
| Metrics / logs | Prometheus or VictoriaMetrics / VictoriaLogs or Loki | |
| Renovate in the cluster | Renovate operator, plain CronJob | GitHub App or fine-grained token. |
| Cluster endpoint | DNS round-robin (current) | `kubectl` may wait for a timeout when a node is down. A VIP would need a fixed address, against the "dynamic" rule. |

## To check or watch

The points of each topic are kept in its `evaluations.md`.

- [ ] Network: ECMP and multi-WAN on OPNsense, the NAS *Pre Init* script, the ISP prefix change, the Milkywan WireGuard tunnel (planned, stable public prefix), Cilium `bpf.masquerade`: [network/evaluations.md](network/evaluations.md#open-points).
- [ ] Nodes: watchdog, `nfsrahead`, Talos firmware updates, firmware reset to the factory Secure Boot keys, serial of SATA disks, `EthernetConfig` alias, TPM unlock failure seen once on kube-01, Dell *Microsoft UEFI CA*: [nodes/evaluations.md](nodes/evaluations.md#open-points).
- [ ] Cluster: Intel DRA driver, network policies (Talos host DNS): [cluster/evaluations.md](cluster/evaluations.md#open-points).
- [ ] Storage: LINSTOR thin pool oversubscription, Talos and the LINSTOR VG, Piraeus `talos-loader-override`: [storage/evaluations.md](storage/evaluations.md#open-points).
- [ ] Ingress: Envoy Gateway listeners after an upgrade (`ecdhCurves`): [ingress/evaluations.md](ingress/evaluations.md#open-points).
- [ ] Backups: Kopiur, to look at again in early 2027 ([checklist](backups/evaluations.md#kopiur-evaluated-to-revisit)).
- [ ] Token expirations: Docker Hub, GitHub (Flux, Renovate), Cloudflare (cert-manager, external-dns, cloudflare-ddns, OpenTofu), see the [tokens to renew](secrets/runbook.md#tokens-to-renew).
- [ ] Workstation 1Password service account: rotate its token every 30 days (`opsa` warns 5 days before and refuses to run past the limit), see [secrets/runbook.md](secrets/runbook.md#rotating-the-workstation-token).
