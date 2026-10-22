# Roadmap

What is left to build on the Kubernetes cluster, the decisions already made (and why), and the questions still open. The manual steps of the first bootstrap are in [first-bootstrap.md](first-bootstrap.md).

## Current state

| Area | Status |
| --- | --- |
| Talos machine configs (`talos/`) | Done: Secure Boot, TPM disk encryption, disks and NIC selectors, dynamic network, NTP, NUT, watchdog, i915, image verification. |
| Bootstrap (`bootstrap/`, `just bootstrap cluster`) | Done: Cilium (+ BGP and LB pools), CoreDNS, External Secrets, Flux. |
| GitOps (`kubernetes/apps`) | Flux, External Secrets + 1Password store, Cilium, CoreDNS, cert-manager (no issuer), Intel GPU device plugin. |
| OpenTofu (`tofu/cloudflare`) | Skeleton only, the existing zones are not imported yet. |
| First bootstrap | In progress, with kube-01 and kube-03 only. |

## Decisions made

Kept here so they are not reopened by accident. Change them only for a new reason.

### Tooling

- Talos configs: plain machine config documents templated with minijinja, secrets resolved by `op inject`. No talhelper (unmaintained), no Omni, no Cluster API, no Terraform provider for Talos.
- GitOps: Flux (flux-operator + flux-instance), Kustomize + `HelmRelease` with charts from `OCIRepository`. The bootstrap helmfile reads the chart, version and values from `kubernetes/apps`, which stays the single source of truth.
- Secrets: 1Password. Locally with a read-only service account (`infrastructure` and `kubernetes` vaults) from the toolbox, for Talos, bootstrap and OpenTofu, see [1password-local-access.md](1password-local-access.md). In the cluster with External Secrets Operator (`kubernetes` vault, read-only service account). ESO keeps the provider replaceable.
- Updates: Renovate, run from the cluster. Talos and Kubernetes upgrades: tuppr.
- Tools: pinned in `mise.toml` (kubectl and talosctl follow the cluster versions).
- Cloudflare (2 DNS zones and other resources): OpenTofu, encrypted state committed.

### Nodes

- Secure Boot with the Sidero Labs keys, enrolled automatically by the ISO, **without** the Microsoft certificates.
- STATE, EPHEMERAL and the NVMe raw volume (`r-storage`) encrypted by the TPM, bound to PCR 11 only (`pcrs: []`): firmware and dbx updates do not lock the disks. A node whose TPM can no longer unlock its disks is rebuilt, the data is replicated elsewhere.
- Disks selected by unique hardware identifier: WWID for the SATA SSDs (Talos leaves their serial empty), serial number for the NVMe SSDs. NIC selected by permanent MAC address (`lan0` alias).
- SATA SSD: Talos only (default layout). NVMe SSD: one unformatted encrypted partition for OpenEBS.
- No swap, no zswap. Weekly fstrim with `allowDiscards`, weekly XFS scrub.
- `watchdog0` (iTCO) armed, NUT client shutting down 90 s after the UPS goes on battery.
- No Talos ingress firewall: OPNsense filters everything entering the nodes subnet. Pod ↔ node isolation will come from Cilium network policies.
- iGPU used on kube-01 and kube-02 only (`shelltopia.net/intel-gpu` label). The UHD 630 of kube-03 is not exposed.

### Network

- Everything dynamic, FQDN wherever possible: DHCPv4 static mappings, SLAAC with EUI-64 addresses, `ntp-01.shelltopia.net`, `ups-01-dmz.shelltopia.net`.
- Node names have **AAAA records only** (ULA): hosts must use IPv6 ULA to reach them. No A record is needed.
- The GUA prefix may change: it is never used in the configs, except in the `external` LB pool and the matching OPNsense prefix list.
- Cluster endpoint: DNS round-robin `kube-cluster01.shelltopia.net` (one AAAA per node).
- Dual-stack, **IPv4 primary**: applications listening on `0.0.0.0` only keep working. Services that must answer over IPv6 use `ipFamilyPolicy: PreferDualStack`.
- Pods `10.244.0.0/16` + `fd1b:654d:9afe:100::/56`, services `10.96.0.0/12` + `fd1b:654d:9afe:200::/112`. The ULA `/48` is dedicated to the cluster and never advertised. These ranges are permanent.
- Cilium: native routing, kube-proxy replacement through KubePrism, **iptables masquerading** (not `bpf.masquerade`: its IPv6 support is beta and always uses the GUA as source, even towards ULA destinations).
- CoreDNS: the Talos one is disabled, replaced by the Helm chart (2 replicas, forwards to the Talos host DNS).
- BGP: eBGP, OPNsense AS 64512, nodes AS 64513, one session per address family, nodes open the sessions to OPNsense listen ranges. The IPv6 peer is written as is (`fd38:4c4d:8f66:f::1`): router advertisement gateways are link-local, which Cilium cannot use. Inbound prefix lists limited to the pools, nothing advertised to the nodes, no MD5.
- LB pools: `internal` (default, `192.168.19.0/25` + `fd38:4c4d:8f66:13::/64`) and `external` (label `lbipam.shelltopia.net/pool: external`, `192.168.19.128/25` + `2a02:8434:f003:d113::/64`). Internet exposure is still decided by OPNsense.
- NAS: static, non-EUI-64 ULA on its nodes subnet interface, router advertisements disabled there by a *Pre Init* script, so its only default routes stay on its main interface (no asymmetric path).

### Applications

- GPU: Intel device plugin through the operator, `sharedDevNum: 3` (Plex, Immich). DRA rejected for now: the Intel DRA driver (0.12.x) only allocates whole GPUs and is beta.
- Storage: OpenEBS rather than Longhorn (no iSCSI extension). Media stay on the NAS over NFS 4.2.
- No registry cache: Docker Hub credentials in containerd avoid the rate limit.

## To implement

Roughly in priority order.

### 1. Finish the test bootstrap

- [ ] Phases 4 to 8 of [first-bootstrap.md](first-bootstrap.md) with kube-01 and kube-03.
- [ ] `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`: final repository URL and branch (`TODO`), `pullSecret` if the repository is private.

### 2. Certificates

- [ ] `ClusterIssuer` Let's Encrypt (staging, then production), DNS-01 with Cloudflare.
- [ ] Cloudflare API token (*Zone → DNS → Edit*, restricted to the zones) in the `kubernetes` vault, synced by an `ExternalSecret` in `cert-manager`.
- [ ] The internal DNS is split-horizon (Unbound overrides `shelltopia.net`): set `dns01RecursiveNameservers` (public resolvers) and `dns01RecursiveNameserversOnly: true` in the cert-manager values, otherwise the propagation check may query Unbound and never succeed.

### 3. Ingress

- [ ] Choose the Gateway API implementation (open decision below).
- [ ] One internal and one external Gateway, matching the `internal` and `external` LB pools.
- [ ] OPNsense: IPv4 port forwarding to the external Gateway IPv4 address, IPv6 WAN rule to the external pool. Replaces the HAProxy SNI proxy currently used for the IPv4 HTTPS traffic.

### 4. DNS records

- [ ] Decide how the records of the applications are created (open decision below): Cloudflare for the public names, Unbound for the internal ones.
- [ ] Import the existing Cloudflare zones in OpenTofu (`tofu/cloudflare`, appendix of first-bootstrap.md).

### 5. Storage

- [ ] Choose the OpenEBS engine (open decision below) and add its Talos prerequisites if any (kernel modules, hugepages, node labels, privileged namespace).
- [ ] Use `/dev/mapper/luks2-r-storage` as the backing device.
- [ ] NFS access to the NAS (open decision below). The NAS exports must allow the nodes subnet. Check the read-ahead (`nfsrahead`, phase 8 of first-bootstrap.md).

### 6. Backups

- [ ] etcd snapshots: needs the `os:etcd:backup` role and the namespace of the backup tool in `KubeTalosAPIAccessConfig` (`talos/patches/kubernetes.yaml.j2`).
- [ ] Application volumes and databases (CloudNativePG): tool and destination still open.
- [ ] The Talos secrets bundle is already in 1Password, nothing else to back up for Talos itself.

### 7. Upgrades

- [ ] Deploy tuppr in `system-upgrade` (Talos API access already allowed for this namespace, role `os:admin`).
- [ ] Decide where the Talos and Kubernetes versions live (open decision below) and update `.renovaterc.json5`: its package rules still describe manual upgrades with `just talos upgrade-node` / `upgrade-k8s`.
- [ ] Deploy Renovate in the cluster (GitHub token through ESO).

### 8. Observability

- [ ] Metrics stack, then enable the `ServiceMonitor`/`PodMonitor` already prepared: Cilium, Cilium operator, CoreDNS, cert-manager, External Secrets, Flux. Control plane metrics are already exposed (etcd `:2381`, scheduler and controller-manager bound to `0.0.0.0`).
- [ ] Logs: VictoriaLogs or Loki, a collector in the cluster, and the Talos service and kernel logs sent to it (`machine.logging` / `KmsgLogConfig`) through an FQDN.

### 9. Security

- [ ] Cilium network policies (replaces the Talos ingress firewall that was dropped), at least to protect the node ports (Talos API, kubelet, etcd) from the pods.
- [ ] Optional: Hubble for flow visibility.

### 10. Migration

- [ ] Move the services of the Hetzner VM, then delete the VM.
- [ ] Move the services of `home`, then turn it into kube-02 ([appendix](first-bootstrap.md#appendix--adding-kube-02)). Until then, the 2-node etcd has no fault tolerance.
- [ ] Replace calibre (KasmVNC) with another application.
- [ ] Rewrite `README.md` once Ansible is gone (it still describes the Fedora CoreOS setup).

### 11. Kubernetes recipes

- [ ] `kubernetes/mod.just` module (`just kube ...`), ideas taken from [onedr0p/home-ops](https://github.com/onedr0p/home-ops/blob/main/kubernetes/mod.just):
  - `sync <hr|ks|gitrepo|ocirepo|es>`: force the reconciliation of every resource of a kind (`reconcile.fluxcd.io/requestedAt` annotation).
  - `debug-node <node>`: `kubectl debug node --profile=sysadmin`, removing the debug pod on exit. The only way to get a shell on a Talos node.
  - `prune-pods`: delete the Failed, Succeeded and Pending pods.
  - `browse-pvc` and `view-secret`: need the `browse-pvc` and `view-secret` kubectl plugins.
  - `apply-ks` / `delete-ks`: apply a Flux Kustomization from the working copy, with `flate` or `flux build ks`.

## Open decisions

| Topic | Options | Notes |
| --- | --- | --- |
| Gateway API implementation | Cilium Gateway API, Envoy Gateway, others | Cilium avoids another component, Envoy Gateway is more complete. Must handle dual-stack LoadBalancer Services. |
| Application DNS records | external-dns (Cloudflare provider) for public names; for Unbound, a webhook provider or manual records | Check whether a maintained external-dns provider for OPNsense/Unbound exists. |
| OpenEBS engine | Replicated PV (Mayastor), Local PV (LVM/ZFS) with replication by the applications | Mayastor needs hugepages, the `nvme_tcp` module and dedicated CPU cores, to check against its docs and the 16 GB of RAM. With 2 test nodes, replication is limited to 2. |
| NFS access | native `nfs` volumes, csi-driver-nfs | `nfsrahead` covers both. |
| Backups | VolSync (restic/kopia), CloudNativePG backups to S3, etcd snapshots | Destination to choose: NAS (S3 service) and/or an off-site provider. |
| Talos/Kubernetes version source | `talos/vars.yaml` (+ mise) or tuppr resources | Renovate should bump both in the same PR, or one should reference the other. |
| Metrics / logs | Prometheus or VictoriaMetrics / VictoriaLogs or Loki | |
| Renovate in the cluster | Renovate operator, plain CronJob | GitHub App or fine-grained token. |
| Cluster endpoint | DNS round-robin (current) | `kubectl` may wait for a timeout when a node is down. A VIP would need a fixed address, against the "dynamic" rule. |

## To check or watch

- [ ] ECMP on OPNsense: FRR selects every path; the kernel installs them once `net.route.multipath=1` (phase 3). Check that the flows are actually spread across the nodes: FreeBSD picks the next hop from the flow hash of the packet, which depends on the NIC driver.
- [ ] Multi-WAN (4G backup, Milkywan WireGuard tunnel) with `net.route.multipath=1`: OPNsense gateway groups use pf `route-to` rules, unaffected, but the routes OPNsense writes in the kernel table are. After setting up and during a failover test, `netstat -rn | grep default` and `netstat -rn -f inet6 | grep default` must show a single line each. Give each gateway its own monitor IP (dpinger host routes). If a duplicate shows up, `net.route.multipath=0` only costs the BGP ECMP.
- [ ] Watchdog: `watchdog0` exists and is armed on kube-01 and kube-03 under Talos.
- [ ] The NAS *Pre Init* script survives TrueNAS upgrades.
- [ ] `nfsrahead`: siderolabs/extensions#1255 moves its configuration to `/etc/nfs.conf` (`talos/patches/nfs.yaml` is ready for it).
- [ ] Talos firmware updates (announced by Sidero Labs): to use for the BIOS updates. The disk encryption is not bound to the firmware measurements.
- [ ] Intel DRA driver: switch from the device plugin once it supports shared GPUs (DRAConsumableCapacity).
- [ ] Cilium `bpf.masquerade`: reconsider once its IPv6 support is stable and picks the source address per destination (it would bring eBPF host routing).
- [ ] Token expirations: Docker Hub, GitHub (Flux, Renovate), Cloudflare.
- [ ] Firmware reset to the factory Secure Boot keys (some BIOS updates do it): enroll the Sidero Labs keys again before booting Talos.
- [ ] Talos: serial of SATA disks behind AHCI controllers (transport `sata`) not detected. If fixed upstream, the SATA SSDs could go back to serial selectors (optional, the WWID is as good).
- [ ] Talos: `EthernetConfig` does not resolve link aliases (v1.14.4, the name is passed as is to ethtool), the node files use the kernel interface names (`enp2s0`, `eno1`). If fixed upstream, move it back to `patches/network.yaml.j2` with `name: lan0`.
- [ ] ISP prefix change: follow [ipv6-prefix-change.md](ipv6-prefix-change.md).
- [ ] Milkywan WireGuard tunnel (planned): stable public IPv4 and IPv6 prefix. The `external` pool, the OPNsense prefix list and the NAT rules will move to it.
- [ ] Workstation 1Password service account: rotate its token every 30 days (`opsa` warns 5 days before and refuses past the limit), see [1password-local-access.md](1password-local-access.md#rotation).
