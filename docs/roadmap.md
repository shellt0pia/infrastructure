# Roadmap

What is left to build on the Kubernetes cluster, and the questions still open. The decisions already made are in the `README.md` of each [topic](README.md#topics). The manual steps of the first bootstrap are in [first-bootstrap.md](first-bootstrap.md).

## Current state

| Area | Status |
| --- | --- |
| Talos machine configs (`talos/`) | Done: Secure Boot, TPM disk encryption, disks and NIC selectors, dynamic network, NTP, NUT, watchdog, i915, DRBD, image verification. |
| Bootstrap (`bootstrap/`, `just bootstrap cluster`) | Done: Cilium (+ BGP and LB pools), CoreDNS, External Secrets, Flux. |
| GitOps (`kubernetes/apps`) | Flux, External Secrets + 1Password store, Cilium, CoreDNS, cert-manager + Let's Encrypt issuers (staging and production, DNS-01 with Cloudflare), Intel GPU device plugin, Envoy Gateway + `internal` and `external` Gateways, application DNS (k8s-gateway, external-dns, cloudflare-ddns), storage (Piraeus/LINSTOR, snapshot-controller). |
| OpenTofu (`tofu/`) | States in B2 (encrypted, no locking). `backblaze`: buckets and keys of the backups, applied, keys pushed to 1Password. `cloudflare`: records not managed from the cluster (mail, CAA, PikaPods), SSL settings and DNSSEC, applied. |
| First bootstrap | In progress, with kube-01 and kube-03 only. |

## To implement

Roughly in priority order.

### 1. Finish the test bootstrap

- [x] The [first bootstrap](first-bootstrap.md), from the first boot to the checks of the cluster, with kube-01 and kube-03.
- [x] `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`: final repository URL and branch (`TODO`), `pullSecret` if the repository is private.

### 2. Certificates

- [x] `ClusterIssuer` Let's Encrypt (staging, then production), DNS-01 with Cloudflare.
- [x] Cloudflare API token (*Zone → DNS → Edit* and *Zone → Zone → Read*, restricted to the zone) in the `kubernetes` vault (item `cloudflare-cert-manager`, field `credential`), synced by an `ExternalSecret` in `cert-manager`.
- [x] The internal DNS is split-horizon (Unbound overrides `shelltopia.net`): `dns01RecursiveNameservers` (public resolvers) and `dns01RecursiveNameserversOnly: true` set in the cert-manager values, otherwise the propagation check may query Unbound and never succeed.
- [x] Wildcard `Certificate` `*.shelltopia.org`: created with the Gateways (step 3), in their namespace (`network`).
- [x] Test with staging after the first deployment, then switch the wildcard `Certificate` to `letsencrypt-production` ([ingress/runbook.md](ingress/runbook.md#testing-a-change-with-the-staging-issuer)).

### 3. Ingress

- [x] Choose the Gateway API implementation: Envoy Gateway.
- [x] One internal and one external Gateway, matching the `internal` and `external` LB pools.
- [x] Deploy and test, see [ingress/bootstrap.md](ingress/bootstrap.md#1-deploy-and-check).
- [x] OPNsense: firewall rules, IPv6 WAN rule to the external pool (TCP 80/443 only), HAProxy rules sending the migrated names to the external Gateway with the PROXY protocol, see [ingress/bootstrap.md](ingress/bootstrap.md#2-opnsense).
- [ ] Once `home` is migrated (step 10): IPv4 port forwarding 80/443 to the external Gateway instead of HAProxy, and removal of the PROXY protocol listeners.

### 4. DNS records

- [x] Decide how the records of the applications are created: k8s-gateway + Unbound forward for the internal names, external-dns + cloudflare-ddns for the public ones, see [dns/README.md](dns/README.md#overview).
- [x] Split the `envoy` GatewayClass into `internal` and `external`.
- [x] Create the Cloudflare tokens and the 1Password items `cloudflare-external-dns` and `cloudflare-ddns` ([dns/bootstrap.md](dns/bootstrap.md#prerequisites)).
- [x] Deploy, then OPNsense: Unbound query forwarding of `shelltopia.org` to k8s-gateway, removal of the host overrides of the migrated names, HAProxy real servers checked after the GatewayClass split ([dns/bootstrap.md](dns/bootstrap.md#2-opnsense-unbound)).
- [x] Checks: [dns/bootstrap.md](dns/bootstrap.md#1-deploy-and-check), external-dns in `dry-run` first.
- [x] Cloudflare records not managed from the cluster, SSL settings and DNSSEC in OpenTofu ([Cloudflare setup](../tofu/README.md#cloudflare-setup)), without the records managed by external-dns and cloudflare-ddns.

### 5. Storage

- [x] Choose the storage: Piraeus/LINSTOR (see the decisions above).
- [x] Talos prerequisites: `siderolabs/drbd` extension (`talos/schematic.yaml`), kernel modules `drbd` (`usermode_helper=disabled`), `drbd_transport_tcp`, `dm-thin-pool` (`talos/patches/drbd.yaml`), privileged namespace.
- [x] Manifests: `kubernetes/apps/piraeus-datastore` (operator, `LinstorCluster`, satellite configurations, storage pool on `/dev/mapper/luks2-r-storage`, StorageClasses, VolumeSnapshotClass) and `kubernetes/apps/kube-system/snapshot-controller`.
- [x] Deploy: new schematic and config on every node **before** Flux applies the manifests, then the checks of [storage/bootstrap.md](storage/bootstrap.md#2-deploy-and-check) (modules, satellites, storage pools, test PVCs, snapshot and restore).
- [ ] Once kube-02 joins: check that the existing 2-replica volumes get their tie-breaker, then the [failover test](storage/bootstrap.md#3-failover-test).
- [ ] NFS access to the NAS: native `nfs` pod volumes, nothing to deploy. The NAS exports must allow the nodes subnet. Check the [read-ahead](nodes/runbook.md#checking-the-nfs-read-ahead) (`nfsrahead`).

### 6. Backups

Architecture: [backups/README.md](backups/README.md), with the deployment, the runbook and the evaluations. Order: volumes, NAS data.

- [x] Test the restricted B2 key (no `deleteFiles`) and the lifecycle rule with restic on a throwaway bucket ([results](backups/evaluations.md#restricted-b2-key-test)).
- [ ] Test the bucket rebuild at a past date with rclone on a new throwaway bucket ([procedure](backups/runbook.md#recovery-after-a-deletion-of-the-backups)): the first test bucket was deleted before this test. Delete the bucket and its keys afterwards.
- [x] etcd: no backup, decision in [backups/evaluations.md](backups/evaluations.md#etcd-not-backed-up), recovery in [backups/runbook.md](backups/runbook.md#etcd-quorum-lost).
- [x] Application volumes: VolSync controller (`kubernetes/apps/backups/volsync`), component `kubernetes/components/volsync`, StorageClass `replicated-temporary`.
- [x] Monitoring: healthchecks.io ping (CronJob `volsync-monitor`). Alertmanager later.
- [x] Restore recipes in `kubernetes/mod.just`: `volsync-snapshots`, `volsync-restic`, `volsync-backup`, `volsync-restore` (credentials from 1Password, B2 readable at a past date; in place, Flux suspended and replicas restored).
- [x] B2 buckets, lifecycle rules and keys in OpenTofu (`tofu/backblaze`), keys pushed to the `restic-*` 1Password items by `just tofu apply`.
- [x] OpenTofu setup ([tofu/README.md](../tofu/README.md#setup)): bucket of the states, admin key (escalation test done: it can create a key with `deleteFiles`, accepted), lock test (B2 does not implement it: locking disabled), first `just tofu apply backblaze` (push to 1Password through `host-spawn op` checked).
- [ ] Deploy: healthchecks check, then the checks of [backups/bootstrap.md](backups/bootstrap.md#2-test-volsync), including the LINSTOR behaviours with a test application.
- [ ] NAS data: Backrest App on TrueNAS ([checklist](backups/bootstrap.md#3-nas-data-backrest)), then stop autorestic and delete the old buckets.
- [ ] PostgreSQL: Barman Cloud plugin of CloudNativePG, implemented with CNPG.
- [ ] Automated restore tests in a throwaway namespace, once applications use VolSync.
- [ ] Monitor the content of the repositories: the healthchecks checks watch the jobs, not the repositories, so a malicious `forget` would go unnoticed. Check the number and age of the snapshots of each repository, compared with the previous run.
- [ ] The Talos secrets bundle is already in 1Password, nothing else to back up for Talos itself.

### 7. Upgrades

- [ ] Deploy tuppr in `system-upgrade` (Talos API access already allowed for this namespace, role `os:admin`).
- [ ] Decide where the Talos and Kubernetes versions live (open decision below) and update `.renovaterc.json5`: its package rules still describe manual upgrades with `just talos upgrade-node` / `upgrade-k8s`.
- [ ] Deploy Renovate in the cluster (GitHub token through ESO).

### 8. Observability

- [ ] Metrics stack, then enable the `ServiceMonitor`/`PodMonitor` already prepared: Cilium, Cilium operator, CoreDNS, cert-manager, External Secrets, Flux. Control plane metrics are already exposed (etcd `:2381`, scheduler and controller-manager bound to `0.0.0.0`).
- [ ] Logs: VictoriaLogs or Loki, a collector in the cluster, and the Talos service and kernel logs sent to it (`machine.logging` / `KmsgLogConfig`) through an FQDN.

### 9. Security

- [ ] Cilium network policies (replaces the Talos ingress firewall that was dropped), at least to protect the node ports (Talos API, kubelet, etcd) from the pods. The host policies must keep the storage ports open between the nodes: LINSTOR satellite TCP 3366 (from the controller pod), DRBD TCP 7000-7999 (`TcpPortAutoRange`), drbd-reactor metrics TCP 9942.
- [ ] Optional: Hubble for flow visibility.

### 10. Migration

- [ ] Move the services of the Hetzner VM, then delete the VM.
- [ ] Move the services of `home`, then turn it into kube-02 ([procedure](nodes/runbook.md#adding-kube-02)). Until then, the 2-node etcd has no fault tolerance. For each migrated name: HAProxy rules to the external Gateway and DNS records ([ingress/runbook.md](ingress/runbook.md#migrating-a-name-from-home)). Per-route needs: basic authentication (`SecurityPolicy` on the route), Plex over HTTPS to its backend (or *Secure connections: Preferred*).
- [ ] Replace calibre (KasmVNC) with another application.
- [ ] Rewrite `README.md` once Ansible is gone (it still describes the Fedora CoreOS setup).

### 11. Kubernetes recipes

- [ ] `kubernetes/mod.just` module (`just kube ...`, already holds the backup recipes), ideas taken from [onedr0p/home-ops](https://github.com/onedr0p/home-ops/blob/main/kubernetes/mod.just):
  - `sync <hr|ks|gitrepo|ocirepo|es>`: force the reconciliation of every resource of a kind (`reconcile.fluxcd.io/requestedAt` annotation).
  - `debug-node <node>`: `kubectl debug node --profile=sysadmin`, removing the debug pod on exit. The only way to get a shell on a Talos node.
  - `prune-pods`: delete the Failed, Succeeded and Pending pods.
  - `browse-pvc` and `view-secret`: need the `browse-pvc` and `view-secret` kubectl plugins.
  - `apply-ks` / `delete-ks`: apply a Flux Kustomization from the working copy, with `flate` or `flux build ks`.

### 12. Cluster tools

- [ ] Reloader ([stakater/Reloader](https://github.com/stakater/Reloader)): Kubernetes (v1.37) still does not restart the pods when a ConfigMap or Secret they use changes. Mounted files are refreshed eventually (not with `subPath`), environment variables never, and most applications only read their configuration at startup. Needed mainly for the Secrets synced by External Secrets (rotated tokens) and the ConfigMaps not generated with a hash suffix. Opt-in per workload (`reloader.stakater.com/auto: "true"` or the explicit `secret.reloader.stakater.com/reload` annotation) rather than watching everything.
- [ ] Web UI to view the cluster, with simple actions (restart a workload, look at logs and events, reconcile Flux). Candidates to compare:
  - Headlamp (kubernetes-sigs): general purpose, plugins (Flux among them), OIDC or token login, the actions follow the RBAC of the user.
  - Flux Operator web UI: already shipped with flux-operator, Flux resources only (status, reconcile, suspend/resume).
  - Kubernetes Dashboard: retired (repository archived in `kubernetes-retired` in January 2026), avoid. Rancher, Portainer: much heavier than needed.
  - Exposure: `internal` Gateway only, behind an authentication (no identity provider yet: OIDC would need one, otherwise basic auth with a `SecurityPolicy`). The service account must not be `cluster-admin`: read-only plus the few verbs needed (`patch` on Deployments/StatefulSets for the restarts).

### 13. Remote node management

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
