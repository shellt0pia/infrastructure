# Roadmap

What is left to build on the Kubernetes cluster, and the questions still open. The decisions already made are in the `README.md` of each [topic](README.md#topics). The manual steps of the first bootstrap are in [first-bootstrap.md](first-bootstrap.md).

## Current state

| Area | Status |
| --- | --- |
| Talos machine configs (`talos/`) | Done: Secure Boot, TPM disk encryption, disks and NIC selectors, dynamic network, NTP, NUT, watchdog, i915, DRBD, image verification. |
| Bootstrap (`bootstrap/`, `just bootstrap cluster`) | Done: Cilium (+ BGP and LB pools), CoreDNS, External Secrets, Flux. |
| GitOps (`kubernetes/apps`) | In use: Flux, External Secrets, Cilium, CoreDNS, cert-manager, Envoy Gateway and the Gateways, the application DNS, the storage and the backups. The status of each is in its [topic](README.md#list). |
| OpenTofu (`tofu/`) | States in B2 (encrypted, no locking). `backblaze`: buckets and keys of the backups, applied, keys pushed to 1Password. `cloudflare`: records not managed from the cluster (mail, CAA, PikaPods), SSL settings and DNSSEC, applied. |
| First bootstrap | In progress, with kube-01 and kube-03 only. |

## To implement

Roughly in priority order. What is done is tracked in the status of each topic, and the detail of each step in its `bootstrap.md`: only what is left is listed here.

### Ingress

- [ ] Once `home` is migrated (see [Migration](#migration)): IPv4 port forwarding 80/443 to the external Gateway instead of HAProxy, and removal of the PROXY protocol listeners ([procedure](ingress/runbook.md#removing-haproxy)).

### Storage

- [ ] Once kube-02 joins: the tie-breakers of the existing volumes, then the [failover test](storage/bootstrap.md#3-failover-test) ([status](storage/README.md#status)).
- [ ] NFS access to the NAS: the exports must allow the nodes subnet, then the [read-ahead check](nodes/runbook.md#checking-the-nfs-read-ahead).

### Backups

Architecture and status: [backups/README.md](backups/README.md#status). Order: volumes, NAS data.

- [ ] The [node down test](backups/bootstrap.md#2-test-volsync) of VolSync.
- [ ] The bucket rebuild at a past date, on a new throwaway bucket ([procedure](backups/runbook.md#recovery-after-a-deletion-of-the-backups), [open point](backups/evaluations.md#open-points)).
- [ ] NAS data: Backrest App on TrueNAS ([checklist](backups/bootstrap.md#3-nas-data-backrest)), then stop autorestic and delete the old buckets.
- [ ] PostgreSQL: Barman Cloud plugin of CloudNativePG, implemented with CNPG.
- [ ] Automated restore tests in a throwaway namespace, once applications use VolSync.
- [ ] Monitor the content of the repositories: the healthchecks checks watch the jobs, not the repositories, so a malicious `forget` would go unnoticed. Check the number and age of the snapshots of each repository, compared with the previous run.

### Upgrades

- [ ] Deploy tuppr in `system-upgrade` (Talos API access already allowed for this namespace, role `os:admin`).
- [ ] Decide where the Talos and Kubernetes versions live ([open decisions](#open-decisions)) and update `.renovaterc.json5`: its package rules still describe manual upgrades with `just talos upgrade-node` / `upgrade-k8s`.
- [ ] Deploy Renovate in the cluster (GitHub token through ESO).

### Observability

- [ ] Metrics stack, then enable the `ServiceMonitor`/`PodMonitor` already prepared: Cilium, Cilium operator, CoreDNS, cert-manager, External Secrets, Flux. Control plane metrics are already exposed (etcd `:2381`, scheduler and controller-manager bound to `0.0.0.0`).
- [ ] Logs: VictoriaLogs or Loki, a collector in the cluster, and the Talos service and kernel logs sent to it (`machine.logging` / `KmsgLogConfig`) through an FQDN.

### Security

- [ ] Cilium network policies (replaces the Talos ingress firewall that was dropped), at least to protect the node ports (Talos API, kubelet, etcd) from the pods. The host policies must keep the storage ports open between the nodes: LINSTOR satellite TCP 3366 (from the controller pod), DRBD TCP 7000-7999 (`TcpPortAutoRange`), drbd-reactor metrics TCP 9942.
- [ ] Optional: Hubble for flow visibility.

### Migration

- [ ] Move the services of the Hetzner VM, then delete the VM.
- [ ] Move the services of `home`, then turn it into kube-02 ([procedure](nodes/runbook.md#adding-kube-02)). Until then, the 2-node etcd has no fault tolerance. For each migrated name: HAProxy rules to the external Gateway and DNS records ([ingress/runbook.md](ingress/runbook.md#migrating-a-name-from-home)). Per-route needs: basic authentication (`SecurityPolicy` on the route), Plex over HTTPS to its backend (or *Secure connections: Preferred*).
- [ ] Replace calibre (KasmVNC) with another application.
- [ ] Rewrite `README.md` once Ansible is gone (it still describes the Fedora CoreOS setup).

### Kubernetes recipes

- [ ] The planned `just kube` recipes, ideas taken from [onedr0p/home-ops](https://github.com/onedr0p/home-ops/blob/main/kubernetes/mod.just) ([list](cluster/runbook.md#the-just-kube-recipes)).

### Cluster tools

- [ ] Reloader ([stakater/Reloader](https://github.com/stakater/Reloader)): Kubernetes (v1.37) still does not restart the pods when a ConfigMap or Secret they use changes. Mounted files are refreshed eventually (not with `subPath`), environment variables never, and most applications only read their configuration at startup. Needed mainly for the Secrets synced by External Secrets (rotated tokens) and the ConfigMaps not generated with a hash suffix. Opt-in per workload (`reloader.stakater.com/auto: "true"` or the explicit `secret.reloader.stakater.com/reload` annotation) rather than watching everything.
- [ ] Web UI to view the cluster, with simple actions (restart a workload, look at logs and events, reconcile Flux). Candidates to compare:
  - Headlamp (kubernetes-sigs): general purpose, plugins (Flux among them), OIDC or token login, the actions follow the RBAC of the user.
  - Flux Operator web UI: already shipped with flux-operator, Flux resources only (status, reconcile, suspend/resume).
  - Kubernetes Dashboard: retired (repository archived in `kubernetes-retired` in January 2026), avoid. Rancher, Portainer: much heavier than needed.
  - Exposure: `internal` Gateway only, behind an authentication (no identity provider yet: OIDC would need one, otherwise basic auth with a `SecurityPolicy`). The service account must not be `cluster-admin`: read-only plus the few verbs needed (`patch` on Deployments/StatefulSets for the restarts).

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
- [ ] Cluster: Intel DRA driver: [cluster/evaluations.md](cluster/evaluations.md#open-points).
- [ ] Storage: LINSTOR thin pool oversubscription, Talos and the LINSTOR VG, Piraeus `talos-loader-override`: [storage/evaluations.md](storage/evaluations.md#open-points).
- [ ] Ingress: Envoy Gateway listeners after an upgrade (`ecdhCurves`): [ingress/evaluations.md](ingress/evaluations.md#open-points).
- [ ] Backups: Kopiur, to look at again in early 2027 ([checklist](backups/evaluations.md#kopiur-evaluated-to-revisit)).
- [ ] Token expirations: Docker Hub, GitHub (Flux, Renovate), Cloudflare (cert-manager, external-dns, cloudflare-ddns, OpenTofu), see the [tokens to renew](secrets/runbook.md#tokens-to-renew).
- [ ] Workstation 1Password service account: rotate its token every 30 days (`opsa` warns 5 days before and refuses to run past the limit), see [secrets/runbook.md](secrets/runbook.md#rotating-the-workstation-token).
