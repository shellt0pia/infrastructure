# Roadmap

What is left to build on the Kubernetes cluster, the decisions already made (and why), and the questions still open. The manual steps of the first bootstrap are in [first-bootstrap.md](first-bootstrap.md).

## Current state

| Area | Status |
| --- | --- |
| Talos machine configs (`talos/`) | Done: Secure Boot, TPM disk encryption, disks and NIC selectors, dynamic network, NTP, NUT, watchdog, i915, DRBD, image verification. |
| Bootstrap (`bootstrap/`, `just bootstrap cluster`) | Done: Cilium (+ BGP and LB pools), CoreDNS, External Secrets, Flux. |
| GitOps (`kubernetes/apps`) | Flux, External Secrets + 1Password store, Cilium, CoreDNS, cert-manager + Let's Encrypt issuers (staging and production, DNS-01 with Cloudflare), Intel GPU device plugin, Envoy Gateway + `internal` and `external` Gateways, application DNS (k8s-gateway, external-dns, cloudflare-ddns), storage (Piraeus/LINSTOR, snapshot-controller). |
| OpenTofu (`tofu/`) | States in B2 (encrypted, no locking). `backblaze`: buckets and keys of the backups, applied, keys pushed to 1Password. `cloudflare`: records not managed from the cluster (mail, CAA, PikaPods), SSL settings and DNSSEC, applied. |
| First bootstrap | In progress, with kube-01 and kube-03 only. |

## Decisions made

Kept here so they are not reopened by accident. Change them only for a new reason.

### Tooling

- Talos configs: plain machine config documents templated with minijinja, secrets resolved by `op inject`. No talhelper (unmaintained), no Omni, no Cluster API, no Terraform provider for Talos.
- GitOps: Flux (flux-operator + flux-instance), Kustomize + `HelmRelease` with charts from `OCIRepository`. The bootstrap helmfile reads the chart, version and values from `kubernetes/apps`, which stays the single source of truth.
- Secrets: 1Password. Locally with a read-only service account (`infrastructure` and `kubernetes` vaults) from the toolbox, for Talos, bootstrap and OpenTofu, see [1password-local-access.md](1password-local-access.md). In the cluster with External Secrets Operator (`kubernetes` vault, read-only service account). ESO keeps the provider replaceable.
- Updates: Renovate, run from the cluster. Talos and Kubernetes upgrades: tuppr.
- Tools: pinned in `mise.toml` (kubectl and talosctl follow the cluster versions).
- Cloudflare (records of the 2 DNS zones not managed from the cluster, SSL settings, DNSSEC; not the zones themselves nor the API tokens, created by hand) and Backblaze B2 (buckets and keys of the backups): OpenTofu, one stack each, states encrypted client-side in a B2 bucket created by hand ([tofu/README.md](../tofu/README.md)).

### Nodes

- Secure Boot with the Sidero Labs keys, enrolled automatically by the ISO, **without** the Microsoft certificates.
- STATE, EPHEMERAL and the NVMe raw volume (`r-storage`) encrypted by the TPM, bound to PCR 11 only (`pcrs: []`): firmware and dbx updates do not lock the disks. A node whose TPM can no longer unlock its disks is rebuilt, the data is replicated elsewhere.
- Disks selected by unique hardware identifier: WWID for the SATA SSDs (Talos leaves their serial empty), serial number for the NVMe SSDs. NIC selected by permanent MAC address (`lan0` alias).
- SATA SSD: Talos only (default layout). NVMe SSD: one unformatted encrypted partition, used whole as the LVM thin pool of LINSTOR (replicated and local volumes share it, no fixed split).
- No swap, no zswap. Weekly fstrim with `allowDiscards`, weekly XFS scrub.
- `watchdog0` (iTCO) armed, NUT client shutting down 90 s after the UPS goes on battery.
- No Talos ingress firewall: OPNsense filters everything entering the nodes subnet. Pod ↔ node isolation will come from Cilium network policies.
- iGPU used on kube-01 and kube-02 only (`shelltopia.net/intel-gpu` label). The UHD 630 of kube-03 is not exposed.

### Network

- Everything dynamic, FQDN wherever possible: DHCPv4 static mappings, SLAAC with EUI-64 addresses, `ntp-01.shelltopia.net`, `ups-01-dmz.shelltopia.net`. Only exception: the addresses of the internal DNS of the applications (k8s-gateway, `192.168.19.53` and `fd38:4c4d:8f66:13::53`), because Unbound only forwards to addresses.
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

- Certificates: Let's Encrypt only, with two permanent `ClusterIssuer`s (`letsencrypt-staging` and `letsencrypt-production`, each `Certificate` picks one) and DNS-01 through Cloudflare. All the services live in `shelltopia.org` (`shelltopia.net` stays for the infrastructure), served by a wildcard `*.shelltopia.org` so that the application names do not appear in the Certificate Transparency logs. One Cloudflare token (*Zone → DNS → Edit*, *Zone → Zone → Read*), created by hand and distinct from the OpenTofu one: 1Password item `cloudflare-cert-manager`, field `credential`. The ACME propagation check only uses the public resolvers of Cloudflare, over plain DNS.
- Ingress: Envoy Gateway (Gateway API), see [ingress.md](ingress.md). Cilium Gateway API stays disabled: Envoy Gateway is more complete (client, backend and security policies, PROXY protocol, HTTP/3) and its proxies are separate from the CNI. Two Gateways in `network`, `internal` and `external`, one per LB pool, each with its own Envoy proxies (`EnvoyProxy`, 2 replicas, `externalTrafficPolicy: Local`) and the same wildcard certificate. Each application chooses its Gateway(s); only the namespaces labeled `shelltopia.net/gateway-external: "true"` can use the external one. The internal Gateway only answers RFC 1918 and `fd00::/8` clients. TLS 1.3 only, `X25519MLKEM768` first, HTTP/3 on the internal Gateway only. Port 80 only redirects to HTTPS.
- IPv4 HTTP(S) from the internet: HAProxy on OPNsense (SNI on 443, Host on 80) keeps sending the names of `home` to it and sends the migrated names to the `external` Gateway on 8080/8443 with the PROXY protocol, until `home` is migrated. Then a plain port forwarding to 80/443 of the Gateway replaces it and the PROXY protocol listeners are removed. IPv6 reaches the Gateway directly.
- Application DNS, driven by the HTTPRoutes, see [ingress.md](ingress.md#dns). One GatewayClass per Gateway (`internal`, `external`) so that the tools can tell them apart.
  - Internal: k8s-gateway (CoreDNS + k8s_gateway) is authoritative for `shelltopia.org` from the routes of the `internal` Gateway, Unbound forwards the zone to it. No external-dns webhook for OPNsense/Unbound. Losing the zone on the LAN while the cluster is down is accepted.
  - Public: hybrid. external-dns (Cloudflare provider) publishes one CNAME per route of the `external` Gateway to the entry name `gateway-external.kube-cluster01.shelltopia.net`, and the `AAAA` of that name (IPv6 of the Gateway). cloudflare-ddns publishes its `A` (WAN IPv4) until the Milkywan tunnel brings a stable one. OpenTofu keeps the zones, the infrastructure records and the names of `home`. The list of the public names is visible in the zone, accepted.
  - Cloudflare tokens: one per tool (`cloudflare-external-dns` on both zones, `cloudflare-ddns` on `shelltopia.net`), in the `Kubernetes` vault.
  - Replaces the `ddns-updater` instances of the Ansible hosts for the migrated names.

- GPU: Intel device plugin through the operator, `sharedDevNum: 3` (Plex, Immich). DRA rejected for now: the Intel DRA driver (0.12.x) only allocates whole GPUs and is beta.
- Storage: Piraeus/LINSTOR (DRBD 9), in `piraeus-datastore`. Chosen over Mayastor (hugepages, dedicated CPU cores, NVMe-oF): in-kernel replication, light on CPU and RAM, CSI snapshots on LVM thin, automatic failover with the HA controller.
  - One LVM thin pool `nvme` per node on `/dev/mapper/luks2-r-storage` (whole NVMe SSD).
  - StorageClass `replicated` (default): 2 replicas, diskless access from the other nodes, quorum from an automatic diskless tie-breaker on the third node. 3 replicas rejected: losing 2 nodes means a restore anyway, and every write would cross the single 1 Gb/s NIC twice.
  - StorageClass `local`: 1 replica without DRBD, for data replicated by the application or disposable (metrics, logs, caches). TopoLVM only if this does not work out.
  - Both classes `reclaimPolicy: Retain`, ext4, `WaitForFirstConsumer`. VolumeSnapshotClass `linstor` (default), snapshot-controller in `kube-system`.
  - Quorum policy: operator defaults (`suspend-io`), required by the HA controller. DRBD resync capped at 50 MiB/s (single NIC).
  - DRBD over the node addresses (satellites in the host network, dual-stack, DRBD over the IPv6 ULA address with `PrefNic`), no dedicated VLAN, no DRBD or LINSTOR TLS (the nodes subnet is trusted).
  - No volumes for the bulk data: media, Immich library, Nextcloud data and mail/calendar archives stay on the NAS, mounted with native `nfs` pod volumes (NFS 4.2, no csi-driver-nfs).
  - The DRBD module comes from the `siderolabs/drbd` extension and is loaded by Talos (`talos/patches/drbd.yaml`); the satellite module loader is removed (`talos-loader-override`).
- No registry cache: Docker Hub credentials in containerd avoid the rate limit.

## To implement

Roughly in priority order.

### 1. Finish the test bootstrap

- [x] Phases 4 to 8 of [first-bootstrap.md](first-bootstrap.md) with kube-01 and kube-03.
- [x] `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`: final repository URL and branch (`TODO`), `pullSecret` if the repository is private.

### 2. Certificates

- [x] `ClusterIssuer` Let's Encrypt (staging, then production), DNS-01 with Cloudflare.
- [x] Cloudflare API token (*Zone → DNS → Edit* and *Zone → Zone → Read*, restricted to the zone) in the `kubernetes` vault (item `cloudflare-cert-manager`, field `credential`), synced by an `ExternalSecret` in `cert-manager`.
- [x] The internal DNS is split-horizon (Unbound overrides `shelltopia.net`): `dns01RecursiveNameservers` (public resolvers) and `dns01RecursiveNameserversOnly: true` set in the cert-manager values, otherwise the propagation check may query Unbound and never succeed.
- [x] Wildcard `Certificate` `*.shelltopia.org`: created with the Gateways (step 3), in their namespace (`network`).
- [x] Test with staging after the first deployment, then switch the wildcard `Certificate` to `letsencrypt-production` ([ingress.md](ingress.md#certificate)).

### 3. Ingress

- [x] Choose the Gateway API implementation: Envoy Gateway.
- [x] One internal and one external Gateway, matching the `internal` and `external` LB pools.
- [x] Deploy and test, see [ingress.md](ingress.md#checks).
- [x] OPNsense: firewall rules, IPv6 WAN rule to the external pool (TCP 80/443 only), HAProxy rules sending the migrated names to the external Gateway with the PROXY protocol, see [ingress.md](ingress.md#opnsense).
- [ ] Once `home` is migrated (step 10): IPv4 port forwarding 80/443 to the external Gateway instead of HAProxy, and removal of the PROXY protocol listeners.

### 4. DNS records

- [x] Decide how the records of the applications are created: k8s-gateway + Unbound forward for the internal names, external-dns + cloudflare-ddns for the public ones, see [ingress.md](ingress.md#dns).
- [x] Split the `envoy` GatewayClass into `internal` and `external`.
- [x] Create the Cloudflare tokens and the 1Password items `cloudflare-external-dns` and `cloudflare-ddns` ([ingress.md](ingress.md#public-external-dns-and-cloudflare-ddns)).
- [x] Deploy, then OPNsense: Unbound query forwarding of `shelltopia.org` to k8s-gateway, removal of the host overrides of the migrated names, HAProxy real servers checked after the GatewayClass split ([ingress.md](ingress.md#opnsense-unbound)).
- [x] Checks: [ingress.md](ingress.md#checks), external-dns in `dry-run` first.
- [x] Cloudflare records not managed from the cluster, SSL settings and DNSSEC in OpenTofu ([Cloudflare setup](../tofu/README.md#cloudflare-setup)), without the records managed by external-dns and cloudflare-ddns.

### 5. Storage

- [x] Choose the storage: Piraeus/LINSTOR (see the decisions above).
- [x] Talos prerequisites: `siderolabs/drbd` extension (`talos/schematic.yaml`), kernel modules `drbd` (`usermode_helper=disabled`), `drbd_transport_tcp`, `dm-thin-pool` (`talos/patches/drbd.yaml`), privileged namespace.
- [x] Manifests: `kubernetes/apps/piraeus-datastore` (operator, `LinstorCluster`, satellite configurations, storage pool on `/dev/mapper/luks2-r-storage`, StorageClasses, VolumeSnapshotClass) and `kubernetes/apps/kube-system/snapshot-controller`.
- [x] Deploy: new schematic and config on every node **before** Flux applies the manifests, then the checks of [first-bootstrap.md](first-bootstrap.md#phase-9--storage) (modules, satellites, storage pools, test PVCs, snapshot and restore).
- [ ] Once kube-02 joins: check that the existing 2-replica volumes get their tie-breaker, then the failover test ([first-bootstrap.md](first-bootstrap.md#phase-9--storage)).
- [ ] NFS access to the NAS: native `nfs` pod volumes, nothing to deploy. The NAS exports must allow the nodes subnet. Check the read-ahead (`nfsrahead`, phase 8 of first-bootstrap.md).

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

- [ ] Cilium network policies (replaces the Talos ingress firewall that was dropped), at least to protect the node ports (Talos API, kubelet, etcd) from the pods. The host policies must keep the storage ports open between the nodes: LINSTOR satellite TCP 3366 (from the controller pod), DRBD TCP 7000-7999 (`TcpPortAutoRange`), drbd-reactor metrics TCP 9942.
- [ ] Optional: Hubble for flow visibility.

### 10. Migration

- [ ] Move the services of the Hetzner VM, then delete the VM.
- [ ] Move the services of `home`, then turn it into kube-02 ([appendix](first-bootstrap.md#appendix--adding-kube-02)). Until then, the 2-node etcd has no fault tolerance. For each migrated name: HAProxy rules to the external Gateway and DNS records ([ingress.md](ingress.md#migrating-a-name-from-home)). Per-route needs: basic authentication (`SecurityPolicy` on the route), Plex over HTTPS to its backend (or *Secure connections: Preferred*).
- [ ] Replace calibre (KasmVNC) with another application.
- [ ] Rewrite `README.md` once Ansible is gone (it still describes the Fedora CoreOS setup).

### 11. Kubernetes recipes

- [ ] `kubernetes/mod.just` module (`just kube ...`), ideas taken from [onedr0p/home-ops](https://github.com/onedr0p/home-ops/blob/main/kubernetes/mod.just):
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

- [ ] Study a way to power cycle a node remotely and, ideally, to see its console without a working OS. A cold power cycle is the only fix found for the TPM unlock failure seen once on kube-01 (see *To check or watch*), and with 3 nodes a stuck node should not need a trip to the rack.
  - Intel AMT: power control and remote KVM out of band. Needs a vPro chipset and CPU (check in the MEBx, `Ctrl+P` at boot), on each node. Very privileged and on the same NIC as Talos: strong password in 1Password, TLS if possible, OPNsense rules so that only the admin workstation reaches the AMT ports (16992-16995, 664). Clients: MeshCommander, `amtterm`/`wsman`.
  - Otherwise: a smart plug (local API, no cloud) per node with *AC Recovery: Power On* in the firmware, power only. Or a PiKVM-like device for the console.
  - Document the procedure in [first-bootstrap.md](first-bootstrap.md#appendix--rebuilding-a-node).

## Open decisions

| Topic | Options | Notes |
| --- | --- | --- |
| Backups | VolSync (restic/kopia, from the `linstor` CSI snapshots), CloudNativePG backups to S3, etcd snapshots | Off-site destination required, the NAS (TrueNAS) as a secondary one. |
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
- [ ] Token expirations: Docker Hub, GitHub (Flux, Renovate), Cloudflare (cert-manager, external-dns, cloudflare-ddns, OpenTofu).
- [ ] Firmware reset to the factory Secure Boot keys (some BIOS updates do it): enroll the Sidero Labs keys again before booting Talos.
- [ ] Talos: serial of SATA disks behind AHCI controllers (transport `sata`) not detected. If fixed upstream, the SATA SSDs could go back to serial selectors (optional, the WWID is as good).
- [ ] Talos: `EthernetConfig` does not resolve link aliases (v1.14.4, the name is passed as is to ethtool), the node files use the kernel interface names (`enp2s0`, `eno1`). If fixed upstream, move it back to `patches/network.yaml.j2` with `name: lan0`.
- [ ] ISP prefix change: follow [ipv6-prefix-change.md](ipv6-prefix-change.md).
- [ ] Envoy Gateway: `ecdhCurves` names are passed as is to Envoy (BoringSSL). After an Envoy upgrade, check that the listeners are not rejected (logs of `envoy-gateway`).
- [ ] Milkywan WireGuard tunnel (planned): stable public IPv4 and IPv6 prefix. The `external` pool, the OPNsense prefix list and the NAT rules will move to it. cloudflare-ddns is then removed and the `A` record of `gateway-external.kube-cluster01.shelltopia.net` becomes static in OpenTofu.
- [ ] LINSTOR thin pool: LINSTOR allows overcommitting it by default. If volumes grow close to the NVMe size, set `MaxOversubscriptionRatio` on the `LinstorCluster` (and watch the thin pool data and metadata usage once the metrics stack is there).
- [ ] Talos and the LINSTOR VG: Talos scans the LVM volumes at boot. Check that it does not activate or complain about the `linstor_nvme` thin pool (`talosctl dmesg`, `talosctl logs` after a reboot).
- [ ] Piraeus on Talos: the `talos-loader-override` satellite configuration follows the Piraeus how-to (`docs/how-to/talos.md`). Compare it with the how-to after each operator upgrade.
- [ ] TPM unlock failure: once, on kube-01, the first boot after the upgrade to the schematic with `drbd` could not unlock `STATE` (`no signatures matching PCR SHA256 digest found in signature JSON`, then `no handlers available to get encryption keys from`). A cold power cycle fixed it. Not reproduced afterwards: several reboots of kube-01 (same PCR 11 value every time), reboots and the same upgrade on kube-03. Fast Boot is off (*Thorough*) on both. Keep a console at hand during the next Talos upgrades; if it happens again, note the boot (first one after an upgrade or not) and the console lines before the error, then report it to Sidero Labs.
- [ ] Dell firmware: *Microsoft UEFI CA* disabled on kube-01 (*Enable for Option ROM* not needed, the iGPU test pod works). Same on kube-03 if its firmware offers the option.
- [ ] Workstation 1Password service account: rotate its token every 30 days (`opsa` warns 5 days before and refuses past the limit), see [1password-local-access.md](1password-local-access.md#rotation).
