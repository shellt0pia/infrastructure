# First cluster bootstrap

Checklist of the manual steps to complete before the first `just bootstrap cluster`. What comes next, the decisions made and the open questions are in [roadmap.md](roadmap.md).

Suggested order: phases 0 to 4 in order. The network (DHCP reservations, DNS records) is prepared before the first boot, so that the nodes are reachable by name from maintenance mode on. Phases 5 and 6 can be done in parallel at any time before phase 7.

## Test phase: 2 nodes

kube-02 is still the `home` host managed by Ansible. The cluster is first built and tested with **kube-01 and kube-03 only**: kube-02 is commented out in `talos/vars.yaml`, so the bootstrap recipes ignore it.

Be aware that an etcd cluster with 2 members has **no fault tolerance**: the quorum is 2, so as soon as one node is down (reboot, upgrade, failure), etcd and the Kubernetes API are unavailable until it comes back. Each Talos upgrade made by tuppr makes the API unavailable during the reboot of the node. This is fine for testing, not for production: the third node restores the tolerance to one failure (see the [appendix](#appendix--adding-kube-02)).

## Phase 0 — Workstation

- [x] Run `mise trust` then `mise install` at the root of the repository.
- [x] Check that `just` and `op` are available. `host-spawn op vault list` (personal account, the workstation service account comes in phase 5 and is scoped to these vaults) must show the `infrastructure` and `kubernetes` vaults. Create the missing ones with `host-spawn op vault create <name>`.
- [x] Open a new shell in the repository and check that `echo $KUBECONFIG $TALOSCONFIG` points to the root of the repository (set by the `[env]` section of `mise.toml`).

## Phase 1 — Hardware and BIOS

| Node | Machine | System disk (SATA, WWID) | Storage disk (NVMe, serial) | NIC | MAC address |
| --- | --- | --- | --- | --- | --- |
| `kube-01` | OptiPlex 3000 Micro | `naa.500a0751e88e1e24` | `2535527309AF` | RTL8111 (`r8169`) | `00:be:43:ef:c8:c9` |
| `kube-02` | OptiPlex 3000 Micro | TODO | TODO | RTL8111 (`r8169`) | `6c:3c:8c:18:d9:1b` |
| `kube-03` | OptiPlex 3060 Micro | `naa.500a07510df503c3` | `24444BCBA81D` | I219-LM (`e1000e`) | `00:4e:01:98:9b:db` |

Talos is installed on the SATA SSD, selected by WWID, and the `lan0` link is the onboard NIC, selected by its permanent MAC address. Both are set in `talos/nodes/kube-0X.yaml.j2`. The NVMe SSD, selected by serial number, holds a single raw volume (`r-storage` partition spanning the whole disk, encrypted by the TPM, not formatted) for the storage solution (OpenEBS), see `talos/patches/storage.yaml`.

The SATA SSDs are selected by WWID because Talos v1.14 leaves the serial of SATA disks empty: it reads the serial from sysfs, where libata does not expose it, and its fallback (udev `ata_id`/`scsi_id` helpers) only runs for the `ata` and `scsi` transports, not for `sata` (AHCI controllers). The WWID is the WWN written in the drive by the manufacturer (`naa.5…`), as unique and stable as the serial.

On each node:

- [x] Update the BIOS **first**. The disk encryption key is not bound to the firmware measurements, so later updates are fine too, but some firmware updates restore the factory Secure Boot keys (see below).
- [x] UEFI only, CSM disabled (already done).
- [x] TPM 2.0 (Intel PTT) enabled and activated.
- [x] *AC power recovery* set to *Power On*, *Wake-on-LAN* set to *LAN only* (already done).
- [x] Put the **internal SATA disk first** in the boot order. Boot from the USB drive with the one-time boot menu (F12), otherwise the node reboots on the ISO after the installation.
- [ ] **Secure Boot: enabled, firmware in setup mode.** On the Dell BIOS: *Secure Boot → Secure Boot Enable*, then *Expert Key Management → Enable Custom Mode* and *Delete All Keys* (the exact wording depends on the BIOS version). In setup mode the firmware accepts new keys without authentication.
- [ ] Check whether the machine has a hardware watchdog: `talosctl --nodes kube-0X.shelltopia.net --insecure ls /sys/class/watchdog` in phase 4. kube-02 has two under Fedora CoreOS (`intel_oc_wdt` and very likely `iTCO_wdt`), but the Talos kernel only ships `iTCO_wdt` and `wdat_wdt`, so `watchdog0` is the PCH TCO watchdog used by `talos/patches/watchdog.yaml`. If a node has no `watchdog0`, Talos logs an error and the rest of the configuration still applies.

The Talos ISO enrolls the Sidero Labs keys automatically (`secureboot.enrollKeys: force` in `talos/schematic.yaml`) **without the Microsoft certificates**: once enrolled, the machine only boots images signed by Sidero Labs. Option ROMs signed by Microsoft (discrete GPU, add-on NIC) would no longer load. The onboard devices of these machines are part of the firmware, they are not affected. To boot anything else again (e.g. a Fedora live USB), restore the factory keys in the BIOS.

## Phase 2 — Talos image

- [ ] Run `just talos schematic-id` to check that the Image Factory responds.
- [ ] Run `just talos download-image`, it downloads `talos/talos-<version>-amd64-secureboot.iso` (ignored by Git).
- [ ] Write the ISO to a USB drive, with Fedora Media Writer or `dd`.

A single USB drive should be enough: Talos runs from RAM once booted, so the nodes can be booted one after the other by removing the drive in between. If a node does not cope with the drive being removed, boot it from the drive again.

## Phase 3 — Network (OPNsense)

Nodes subnet: `192.168.15.0/24`, `fd38:4c4d:8f66:f::/64` (ULA) and `2a02:8434:f003:d10f::/64` (GUA, delegated, may change). Talos configures it dynamically, no address is hardcoded in the machine configuration:

- DHCPv4: IPv4 address, gateway, DNS server and domain name;
- router advertisements: SLAAC with EUI-64 addresses for the ULA and GUA prefixes, RDNSS.

The nodes are reached by name (`kube-0X.shelltopia.net`, `kube-cluster01.shelltopia.net`), IPv6 only: these names have AAAA records with the ULA addresses and no A record. Inside the cluster, IPv4 is the primary family: the primary Kubernetes node IPs are the IPv4 addresses, the ULA addresses come second. etcd peers use both.

| Node | MAC address | Reserved IPv4 | ULA address (EUI-64) | Interface identifier (GUA alias) |
| --- | --- | --- | --- | --- |
| `kube-01` | `00:be:43:ef:c8:c9` | `192.168.15.11` | `fd38:4c4d:8f66:f:2be:43ff:feef:c8c9` | `::2be:43ff:feef:c8c9` |
| `kube-02` | `6c:3c:8c:18:d9:1b` | `192.168.15.12` | `fd38:4c4d:8f66:f:6e3c:8cff:fe18:d91b` | `::6e3c:8cff:fe18:d91b` |
| `kube-03` | `00:4e:01:98:9b:db` | `192.168.15.13` | `fd38:4c4d:8f66:f:24e:1ff:fe98:9bdb` | `::24e:1ff:fe98:9bdb` |

The IPv6 addresses are derived from the MAC addresses (EUI-64: `ff:fe` inserted in the middle, 7th bit of the first byte flipped). They are checked in phase 4.

kube-02 is still the `home` host, which already uses this MAC address: create its records when it is migrated (see the [appendix](#appendix--adding-kube-02)).

### DHCP and router advertisements

- [x] Create a static mapping by MAC address for each node, **outside of the dynamic range**. The IPv4 addresses are not referenced in the repository, they can be changed in OPNsense only.
- [x] Check that the DHCP server of the interface sends the domain name (`shelltopia.net`).
- [x] Check that the router advertisements of the interface still provide SLAAC for both prefixes (A flag), RDNSS and DNSSL.

### DNS (Unbound, internal only)

- [x] Add host overrides `kube-01` and `kube-03` in `shelltopia.net`: **AAAA records only**, with the ULA address of the table.
- [x] Add host overrides **with the same name** `kube-cluster01.shelltopia.net`, one AAAA record per node (ULA address). This DNS round-robin is the `cluster.endpoint`.
- [x] Check that `dig +short AAAA kube-cluster01.shelltopia.net` returns the ULA addresses of the nodes.
- [x] Check that `ntp-01.shelltopia.net` (`network.ntp_servers` in `talos/vars.yaml`) resolves from the nodes subnet.
- [x] **Do not** create these records on Cloudflare: the Kubernetes and Talos APIs must stay internal.

No A record is needed:

- `talosctl`, `kubectl` and Flux connect to these names from the workstation, over IPv6;
- on the nodes, the cluster endpoint is only resolved by KubePrism, through the Talos resolver, and the nodes have their ULA address;
- etcd, the kubelet and the pods use addresses, never these names.

The only requirement is IPv6 connectivity from the administration subnets to the ULA addresses of the nodes.

Known limitation: when a node is down, `kubectl` may pick its address and wait for a timeout before retrying. Inside the cluster, KubePrism is used, so it is not affected.

### Firewall

- [x] Administration subnets (`fd38:4c4d:8f66:a::/64`, and optionally `192.168.10.0/24` and `2a02:8434:f003:d10a::/64`) → nodes: TCP 50000 (Talos API) and 6443 (Kubernetes API). The names only resolve to ULA addresses, so the ULA rule is the one used.
- [x] Nodes → OPNsense: DNS (TCP/UDP 53) and NTP (UDP 123, addresses of `ntp-01.shelltopia.net`).
- [x] Nodes → Internet over HTTPS (443), IPv4 and IPv6:
  - images: `factory.talos.dev`, `ghcr.io`, `registry.k8s.io` (and its CDNs), Docker Hub (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`);
  - image signature verification: `tuf-repo-cdn.sigstore.dev` (Sigstore TUF repository). Without it, the images of `registry.k8s.io`, `ghcr.io/siderolabs` and `factory.talos.dev` cannot be pulled;
  - `discovery.talos.dev` and `github.com` (for Flux).
- [x] Nodes → NUT server (`ups.server` in `talos/vars.yaml`): TCP 3493, if it is not on the nodes subnet. On the NAS, allow the nodes addresses in `upsd.conf`/the NFS exports if they are filtered.
- [x] Between the nodes: everything is on the same subnet, nothing to do. The Talos ingress firewall is not used: OPNsense filters all the traffic entering the nodes subnet. The traffic between the pods and the nodes never goes through it, it will be restricted later with Cilium network policies.
- [x] Nodes subnet (`192.168.15.0/24` and `fd38:4c4d:8f66:f::/64`) → *This Firewall*: TCP 179 (BGP, see below).
- [x] Administration subnets → LoadBalancer pools (internal: `192.168.19.0/25`, `fd38:4c4d:8f66:13::/64` / external: `192.168.19.128/25`, `2a02:8434:f003:d113::/64`): TCP 80 for the test of phase 8. The real rules come with the Gateways.

### BGP (FRR)

The LoadBalancer IPs of the Services are advertised by every node to OPNsense with BGP (Cilium BGP control plane, `kubernetes/apps/kube-system/cilium/networking`):

- eBGP: OPNsense is AS **64512**, all the nodes share AS **64513**;
- one session per address family: IPv4 between the IPv4 addresses, IPv6 between the ULA addresses;
- the nodes open the sessions, OPNsense accepts any node of the subnet through listen ranges: no node address is configured on either side, kube-02 will peer without any change;
- the nodes advertise one /32 or /128 route per LoadBalancer IP, from these pools:

| Pool | IPv4 | IPv6 | Services |
| --- | --- | --- | --- |
| `internal` | `192.168.19.0/25` | `fd38:4c4d:8f66:13::/64` | default |
| `external` | `192.168.19.128/25` | `2a02:8434:f003:d113::/64` (GUA, from the delegated /56) | label `lbipam.shelltopia.net/pool: external` |

These prefixes are only routed through BGP: **do not assign them to any interface**, and do not use them anywhere else.

In *Routing → General*:

- [ ] Enable the routing service.

In *Routing → BGP → General*:

- [ ] Enable BGP, *BGP AS Number* `64512`, *Router ID* `192.168.15.1`. The router ID is optional, but without it FRR picks the highest IPv4 address of OPNsense, possibly the public WAN one: when it changes, every BGP session is reset. It is only an identifier, it does not need to follow a renumbering of the subnet.
- [ ] *Max Paths* `3`: with ECMP, the traffic towards an IP advertised by several nodes is spread across them, and another node keeps receiving it within 9 seconds if one fails.

In *System → Settings → Tunables*:

- [ ] `net.route.multipath` = `1`. OPNsense sets it to `0` by default: FRR then selects every path, but the FreeBSD kernel only installs one next hop per route. Restart FRR after the change so that zebra reinstalls its routes.

In *Routing → BGP → Prefix Lists* (the *Network* field is written as is in the FRR configuration):

| Name | IP version | Seq | Action | Network |
| --- | --- | --- | --- | --- |
| `kube-cluster01-lb-v4` | IPv4 | 10 | Permit | `192.168.19.0/24 le 32` |
| `kube-cluster01-lb-v6` | IPv6 | 10 | Permit | `fd38:4c4d:8f66:13::/64 le 128` |
| `kube-cluster01-lb-v6` | IPv6 | 20 | Permit | `2a02:8434:f003:d113::/64 le 128` |
| `deny-all-v4` | IPv4 | 10 | Deny | `any` |
| `deny-all-v6` | IPv6 | 10 | Deny | `any` |

In *Routing → BGP → Peer Groups*:

| Name | Remote AS | Address family | Listen ranges | Prefix list in | Prefix list out |
| --- | --- | --- | --- | --- | --- |
| `kube-cluster01-v4` | `64513` | IPv4 | `192.168.15.0/24` | `kube-cluster01-lb-v4` | `deny-all-v4` |
| `kube-cluster01-v6` | `64513` | IPv6 | `fd38:4c4d:8f66:f::/64` | `kube-cluster01-lb-v6` | `deny-all-v6` |

- [x] Create the prefix lists and the peer groups above. No neighbor needs to be created.
- [x] The peer group form only offers one entry of a prefix list (`kube-cluster01-lb-v6:10` or `:20`): pick any of them. The plugin renders the reference by **name** (`neighbor kube-cluster01-v6 prefix-list kube-cluster01-lb-v6 in`), and all the entries sharing this name form a single FRR prefix list. Check with `vtysh -c 'show running-config'`: both `ipv6 prefix-list kube-cluster01-lb-v6 seq 10/20` lines must be present.

Notes:

- The inbound prefix lists are the protection against a wrong advertisement: anything outside the pools is ignored, so a mistake in the cluster cannot hijack another network. The outbound ones make sure OPNsense advertises nothing to the nodes (the OPNsense plugin disables the FRR default that requires a policy on eBGP sessions).
- No TCP MD5 password: it is cumbersome on FreeBSD, the listen ranges, the prefix lists and the firewall rule are enough on a dedicated subnet.
- Asymmetric path to avoid: a host which reaches a LoadBalancer IP through OPNsense **with a source address of the nodes subnet** gets the answer directly from the node, so pf only sees one direction and is likely to drop the connection. The NAS is not affected as long as its only default routes (IPv4 and IPv6) are on its main interface (`192.168.14.0/24`): its requests then come from that interface and the answers go back through OPNsense. Check on the NAS that `ip -6 route show default` only lists the main interface: the secondary one receives the router advertisements of the nodes subnet, which may add a second default route. TrueNAS accepts them even on an interface with a static configuration: disable them with a *Pre Init* command (*System → Advanced Settings → Init/Shutdown Scripts*, runs once the network is configured) such as `sysctl -w net.ipv6.conf.vlan15.accept_ra=0 && ip -6 route flush dev vlan15 proto ra && ip -6 addr flush dev vlan15 dynamic`. The router advertisements received before this command still create SLAAC addresses (removed by the last part) and update the lifetimes of a static address equal to the EUI-64 one, which would then expire: give the interface a static ULA address which is not the EUI-64 one.
- If the ISP changes the delegated prefix, follow [ipv6-prefix-change.md](ipv6-prefix-change.md) (`external` pool in `pools.yaml`, `kube-cluster01-lb-v6` prefix list, firewall rules, DNS).

## Phase 4 — First boot in maintenance mode

Boot each node from the USB drive, with the firmware in setup mode:

1. systemd-boot enrolls the Sidero Labs keys and reboots the machine (a countdown is shown on the console).
2. Boot from the USB drive again (F12): Talos starts in maintenance mode, the console shows the addresses obtained through DHCP and SLAAC.

From the workstation, using the names created in phase 3 (if a name does not answer, use the IPv4 address shown on the console and check the DHCP mapping, the router advertisements and the DNS record):

- [ ] `talosctl get securitystate --insecure --nodes kube-0X.shelltopia.net`: `SECUREBOOT` must be `true`. Otherwise, check the BIOS: the TPM disk encryption refuses to enroll without Secure Boot (`checkSecurebootStatusOnEnroll`), so the installation would fail.
- [ ] `talosctl get disks --insecure --nodes kube-0X.shelltopia.net`: check the WWID of the SATA SSD and the serial of the NVMe SSD against the table of phase 1, fill the missing ones in the table and in `talos/nodes/kube-0X.yaml.j2`. The NVMe SSD is entirely repartitioned by Talos at install: make sure it holds nothing worth keeping.
- [ ] `talosctl get links --insecure --nodes kube-0X.shelltopia.net`: the `HW ADDR` of the physical interface must match the MAC address of phase 1, used by the `LinkAliasConfig` of the node file.
- [ ] `talosctl get addresses --insecure --nodes kube-0X.shelltopia.net`: the reserved IPv4 address, the ULA address of phase 3 and a GUA address with the same interface identifier.

## Phase 5 — 1Password

### Workstation service account

- [ ] Create the read-only workstation service account and set up the toolbox and the shell. The recipes reading 1Password need it: `op` in the toolbox only works with its token, set by the `just` shell function. The personal account stays available through `host-spawn op` (one approval per call), see [1password-local-access.md](1password-local-access.md).

### Talos secrets

- [ ] Run `just talos gen-secrets`, it creates the `talos-secrets` document in the `infrastructure` vault (through `host-spawn op`, the service account is read-only: three approvals).

This is the cluster PKI: it is generated **once and never regenerated**. The recipe refuses to overwrite an existing document. `talosconfig` and `kubeconfig` can be regenerated at any time from this document (`just talos talosconfig`, `just bootstrap kubeconfig`), so there is nothing else to back up locally.

### Docker Hub

- [ ] Create a Docker Hub *personal access token* with the *Public Repo Read-only* scope.
- [ ] Store it in the `infrastructure/docker-hub` item, fields `username` and `credential`, referenced by `talos/patches/containerd.yaml.j2`.

### NUT

- [ ] On the NAS, use (or create) a NUT user with the `upsmon secondary` role in `upsd.users`.
- [ ] Store it in the `infrastructure/nut-server` item, fields `username` and `password`, referenced by `talos/patches/extensions.yaml.j2`.

### Service account for External Secrets

- [ ] Create the service account with **read-only access to the `kubernetes` vault only**, either in the web interface (*Developer → Service Accounts*) or with the CLI, signed in with the personal account:

  ```sh
  host-spawn op service-account create "kubernetes-external-secrets" --vault kubernetes:read_items
  ```

  The permissions of a service account cannot be changed after its creation, and the token is shown **only once**.

- [ ] Store the token in the `kubernetes` vault, item `1password-service-account-kubernetes`, field `credential` (*API Credential* category), as referenced in `bootstrap/resources/secrets.yaml.j2`.
- [ ] Check that the reference resolves with the workstation service account (`opsa` provides its token outside `just`):

  ```sh
  opsa op read op://kubernetes/1password-service-account-kubernetes/credential >/dev/null && echo OK
  ```

- [ ] Check the scope of the token. The following command must list **only** the `kubernetes` vault (the inner `op` uses the workstation service account, the outer one the External Secrets token):

  ```sh
  OP_SERVICE_ACCOUNT_TOKEN="$(opsa op read op://kubernetes/1password-service-account-kubernetes/credential)" op vault list
  ```

- [ ] Optional: create a test item in the `kubernetes` vault, to validate External Secrets after the bootstrap.

### Git token for Flux (private repository only)

- [ ] Create a GitHub *fine-grained personal access token*, restricted to this repository, with the *Contents: Read-only* permission. Write down its expiration date.
- [ ] Store it in `op://infrastructure/flux-github-token/credential`.
- [ ] Uncomment the related block in `bootstrap/resources/secrets.yaml.j2`, and `pullSecret: flux-system` in `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`.

## Phase 6 — Git repository

- [ ] In `talos/vars.yaml`, check the cluster ranges, they **cannot be changed** once the cluster is created:
  - IPv4 pods `10.244.0.0/16` and services `10.96.0.0/12`;
  - IPv6 pods `fd1b:654d:9afe:100::/56` and services `fd1b:654d:9afe:200::/112`, carved out of a ULA /48 dedicated to the cluster and never routed outside of it;
  - **IPv4 is the primary family** (first in the lists): single-stack Services get an IPv4 ClusterIP, and the primary pod IP is the IPv4 one, so the kubelet probes use IPv4 and applications listening on `0.0.0.0` only keep working. A Service that must be reachable over IPv6 sets `ipFamilyPolicy: PreferDualStack` (the application must then listen on `::` too).

- [ ] The CNI (Cilium) and CoreDNS are the first releases of `bootstrap/helmfile/apps.yaml.gotmpl`. Flannel, kube-proxy and the CoreDNS managed by Talos are disabled in the Talos configuration: until Cilium runs, the nodes stay `NotReady`. Their values live in `kubernetes/apps/kube-system/{cilium,coredns}/app/helmrelease.yaml` and repeat the cluster ranges of `talos/vars.yaml`: keep them in sync if the ranges are changed before the bootstrap. The CoreDNS service is dual-stack with the cluster DNS addresses given to the kubelet (the 10th address of each service subnet): `10.96.0.10` then `fd1b:654d:9afe:200::a`.
- [ ] The BGP sessions and the LoadBalancer pools in `kubernetes/apps/kube-system/cilium/networking` match the OPNsense configuration of phase 3 (ASNs, pools, ULA address of OPNsense). helmfile applies them right after Cilium.
- [ ] In `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`:
  - `url`: the real URL of the GitHub repository;
  - `ref`: the branch Flux must follow.
- [ ] Commit and push. Meanwhile, check that `git status` shows neither `talosconfig`, `kubeconfig` nor `*.iso`.

Important note about the branch: helmfile installs the bootstrap apps from the local working copy, but Flux then applies what is **on GitHub**, on the configured branch. So either merge into `main` before the bootstrap, or temporarily set `refs/heads/migrate-to-k8s` and switch back to `main` after the merge. Either way, **commit and push** the `sync.ref` value of `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` before the bootstrap: Flux reapplies this HelmRelease from the pushed commit, and an older value would switch the `GitRepository` to another branch (every Kustomization then fails with `kustomization path not found`). To recover, patch `spec.values.instance.sync.ref` of the `flux-instance` HelmRelease in the cluster, then `flux -n flux-system reconcile hr flux-instance --force`.

## Phase 7 — Dry checks

These checks have no impact on the nodes.

- [ ] For each node, the rendered config must be valid:

  ```sh
  talosctl validate --mode metal --strict --config <(just talos render-config kube-01)
  ```

- [ ] helmfile must list the releases with the expected versions:

  ```sh
  cd bootstrap/helmfile && helmfile -f apps.yaml.gotmpl list
  ```

- [ ] The manifests must build:

  ```sh
  kubectl kustomize kubernetes/apps/flux-system && kubectl kustomize kubernetes/apps/external-secrets && kubectl kustomize kubernetes/apps/cert-manager && kubectl kustomize kubernetes/apps/kube-system && kubectl kustomize kubernetes/apps/kube-system/cilium/networking && kubectl kustomize kubernetes/apps/kube-system/intel-device-plugin/gpu
  ```

## Phase 8 — Bootstrap

- [ ] The nodes are booted from the ISO in maintenance mode, each reachable by its name, and the USB drive is removed.
- [ ] Run `just bootstrap cluster` and confirm. Each stage logs its progress (`gum log`). The recipe can safely be run again after a failure: the nodes already configured are skipped and an already bootstrapped etcd is left as is. A single stage can also be run alone, e.g. `just bootstrap apps`.
- [ ] Checks after the bootstrap, on each node:
  - `talosctl health`
  - `talosctl get securitystate`: Secure Boot enabled.
  - `talosctl get volumestatus`: `STATE`, `EPHEMERAL` and `r-storage` are `ready` and encrypted (`luks2`). `talosctl get volumestatus r-storage -o yaml`: the partition spans the whole NVMe SSD, and `mountLocation` is the decrypted device (`/dev/dm-N`). The stable name used later by OpenEBS is the `/dev/mapper/luks2-r-storage` link to it (`talosctl ls -l /dev/mapper`).
  - `talosctl get extensions`: `i915`, `intel-ucode`, `nfsrahead`, `nut-client` and `realtek-firmware`.
  - `talosctl service ext-nut-client`: running, and `talosctl logs ext-nut-client` shows the connection to the UPS.
  - `talosctl get addresses`: the IPv4, ULA and GUA addresses. The IPv6 ones must end with the EUI-64 identifier (`…ff:fe…`).
  - `talosctl get links`: find the kernel name of the `lan0` link, then `talosctl read /proc/sys/net/ipv6/conf/<link>/accept_ra` must return `2` (router advertisements accepted even with forwarding enabled). With `1`, the GUA/ULA addresses would disappear once forwarding is enabled by the CNI.
  - `talosctl image ls --namespace system`: the images have the `talos.dev/verified` label.
  - `talosctl get timeservers`: `ntp-01.shelltopia.net`. Then `talosctl time`: synchronized.
  - `talosctl etcd members`: the peer URLs are the IPv4 and ULA addresses.
  - `talosctl get watchdogtimerstatus`: the watchdog is armed.

  - `talosctl read /system/config/kubernetes/kube-scheduler/scheduler-config.yaml`: the `ImageLocality` plugin is disabled and `PodTopologySpread` has the default constraints.
- [ ] Checks on the cluster:
  - `kubectl get nodes -o wide`: the nodes are `Ready`, without taints, with the IPv4 address as `INTERNAL-IP`. `kubectl get node kube-01 -o jsonpath='{.status.addresses}'` lists the ULA address too.
  - `kubectl get node kube-01 -o jsonpath='{.spec.podCIDRs}'`: one IPv4 /24 from `10.244.0.0/16` and one IPv6 /64 from `fd1b:654d:9afe:100::/56`.
  - `kubectl -n kube-system exec ds/cilium -- cilium-dbg status`: `KubeProxyReplacement: True`, `Routing: Network: Native`, `Masquerading: IPTables [IPv4: Enabled, IPv6: Enabled]`, and every controller healthy.
  - `kubectl -n kube-system exec ds/cilium -- cilium-health status`: every node is reachable.
  - `kubectl logs` and `kubectl exec` on a pod of each node work (kube-apiserver → kubelet, port 10250).
  - `kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIPs}'`: the two cluster IPs `10.96.0.10` and `fd1b:654d:9afe:200::a`. The `CLUSTER-IP` column of `kubectl get svc` only shows the primary one.
  - DNS and egress from a pod:

    ```sh
    kubectl run nettest --rm -it --restart=Never --image=docker.io/nicolaka/netshoot -- bash
    dig kubernetes.default.svc.cluster.local A +short    # 10.96.0.1
    dig ntp-01.shelltopia.net AAAA +short                # resolved by OPNsense through CoreDNS and the Talos host DNS
    curl -6 https://ifconfig.co                          # GUA address of the node (Internet destination)
    ping -6 -c 3 fd38:4c4d:8f66:f::1                     # OK, masqueraded behind the ULA address of the node
    ```

    On OPNsense, the states of the last ping must show the ULA address of the node as source, not its GUA one.
  - BGP sessions: `kubectl -n kube-system exec ds/cilium -- cilium-dbg bgp peers` shows the two sessions of one node (`opnsense-ipv4` with `192.168.15.1`, `opnsense-ipv6` with `fd38:4c4d:8f66:f::1`) as `established`. On OPNsense (*Routing → Diagnostics → BGP* or `vtysh -c 'show bgp summary'`): one IPv4 and one IPv6 neighbor per node, created dynamically (marked with `*`). No prefix is exchanged yet (`Advertised 0`, `PfxRcd 0`, empty routing tables): the nodes only advertise LoadBalancer IPs, and there is no LoadBalancer Service until the test below.
  - `kubectl get ciliumloadbalancerippools`: `internal` and `external`, not `CONFLICTING`.
  - LoadBalancer test:

    ```sh
    kubectl create deployment lbtest --image=docker.io/traefik/whoami --replicas=2
    kubectl apply -f - <<'EOF'
    apiVersion: v1
    kind: Service
    metadata:
      name: lbtest
    spec:
      type: LoadBalancer
      ipFamilyPolicy: RequireDualStack
      selector:
        app: lbtest
      ports:
        - port: 80
    EOF
    kubectl get svc lbtest    # one IPv4 address from 192.168.19.0/25, one from fd38:4c4d:8f66:13::/64
    ```

    On OPNsense, `vtysh -c 'show bgp ipv4 unicast'` and `vtysh -c 'show bgp ipv6 unicast'`: the /32 and /128 routes, one path per node. `netstat -rn | grep 192.168.19` and `netstat -rn -f inet6 | grep fd38:4c4d:8f66:13` show one line per installed next hop: one per node with ECMP (`vtysh -c 'show ip route 192.168.19.1/32'` marks every next hop with `*` even when the kernel keeps only one, see `net.route.multipath` in phase 3). From the workstation, `curl http://<IPv4>` and `curl 'http://[<ULA>]'` answer.

    Then `kubectl label svc lbtest lbipam.shelltopia.net/pool=external`: the addresses move to `192.168.19.128/25` and `2a02:8434:f003:d113::/64`. Clean up with `kubectl delete svc,deployment lbtest`.
  - `kubectl get --raw /api/v1/nodes/kube-01/proxy/configz | jq .kubeletconfig`: `shutdownGracePeriod` is `1m30s`, `serializeImagePulls` is `false` and `crashLoopBackOff.maxContainerRestartPeriod` is `1m0s`.
  - `kubectl -n flux-system get fluxinstance`, then `flux get ks -A` and `flux get hr -A`: everything is `Ready`. cert-manager and the Intel GPU device plugin are only deployed by Flux, after the bootstrap: `intel-device-plugin-operator` waits for `cert-manager`, then `intel-device-plugin-gpu` waits for the operator.
  - `kubectl -n cert-manager get pods`: the controller, the webhook and the cainjector are running. No `ClusterIssuer` exists yet.
  - Intel GPU device plugin:
    - `kubectl get gpudeviceplugins`: `intel-gpu`, with as many ready nodes as desired.
    - `kubectl -n kube-system get pods -o wide | grep intel-gpu-plugin`: one pod on kube-01 only (kube-02 later), none on kube-03.
    - `kubectl get node kube-01 -o jsonpath='{.status.allocatable}'`: `gpu.intel.com/i915` is `3`. kube-03 has no `gpu.intel.com/*` resource.
    - A non-root pod requesting the GPU sees the render node, owned by its user (`device_ownership_from_security_context` in `talos/patches/containerd.yaml.j2`):

      ```sh
      kubectl apply -f - <<'EOF'
      apiVersion: v1
      kind: Pod
      metadata:
        name: gputest
      spec:
        restartPolicy: Never
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
        containers:
          - name: gputest
            image: docker.io/library/busybox
            command: [ls, -ln, /dev/dri]
            resources:
              limits:
                gpu.intel.com/i915: 1
      EOF
      kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gputest
      kubectl get pod gputest -o wide    # scheduled on kube-01
      kubectl logs gputest               # renderD128 (and card0) owned by 1000:1000
      kubectl delete pod gputest
      ```

  - `kubectl get clustersecretstore onepassword`: the `READY` column must be `True`.
  - Create a test `ExternalSecret` targeting the test item of phase 5.

To start over from scratch: `just talos reset-node kube-0X` puts a node back in maintenance mode, then run `just bootstrap cluster` again. The reset wipes `STATE`, `EPHEMERAL` and the `r-storage` raw volume of the NVMe SSD: its key is locked to `STATE` (`lockToState`), it could not be unlocked anymore anyway.

Later, once a NFS volume is mounted by a pod, check the read-ahead set by `nfsrahead`: find the device number of the mount (`0:NN`) with `talosctl read /proc/self/mountinfo`, then `talosctl read /sys/class/bdi/0:NN/read_ahead_kb` must return `16000` (default embedded in the Talos v1.14 extension), or `16384` once the extension reads `/etc/nfs.conf` (`talos/patches/nfs.yaml`).

## Appendix — Adding kube-02

Once `home` has been migrated to the cluster:

- [ ] Install the SATA SSD, then follow phase 1 for this machine.
- [ ] Remove the DHCP mapping and DNS records of `home`, then create those of kube-02 (phase 3).
- [ ] Boot it in maintenance mode (phase 4).
- [ ] Fill the WWID of the SATA SSD and the serial of the NVMe SSD in `talos/nodes/kube-02.yaml.j2`, uncomment kube-02 in `talos/vars.yaml`.
- [ ] `just talos talosconfig`, then `just talos apply-node kube-02 --insecure`. The node joins etcd automatically, check with `talosctl etcd members`.
- [ ] Nothing to do for BGP: the node opens its sessions and OPNsense accepts them through the listen ranges. Check with `vtysh -c 'show bgp summary'`.

## Appendix — Rebuilding a node

The disks are unlocked by the TPM as long as the machine boots a Talos image signed by Sidero Labs with Secure Boot enabled. Firmware updates, kernel arguments changes and Secure Boot database updates do not affect it. The unlocking fails if the TPM is cleared (BIOS reset of the PTT), the motherboard is replaced or Secure Boot is disabled. In that case, rebuild the node:

- [ ] From another node: `talosctl --nodes <other> etcd remove-member kube-0X`, then `kubectl delete node kube-0X`.
- [ ] Boot the node from the ISO (re-enroll the keys if the firmware restored its defaults), then wipe both disks: `talosctl wipe disk sda nvme0n1 --insecure --nodes kube-0X.shelltopia.net` (not tested yet on this hardware). The `r-storage` volume of the NVMe SSD cannot be unlocked anymore either: if it were kept, Talos would find the encrypted partition and fail to open it instead of recreating it.
- [ ] `just talos apply-node kube-0X --insecure`. The data stored by the applications is replicated on the other nodes (CloudNativePG, OpenEBS replication), the storage solution then rebuilds the replicas of this node.

## Appendix — OpenTofu / Cloudflare

Independent from the cluster, can wait.

- [ ] Create a custom Cloudflare API token:
  - *Zone → DNS → Edit* and *Zone → Zone → Read* permissions;
  - restricted to the 2 zones;
  - with additional permissions only for the other resources to manage.
- [ ] Create the `infrastructure/cloudflare-tofu` item with the `credential` (the token) and `account-id` (shown in the Cloudflare dashboard) fields.
- [ ] Create the `infrastructure/tofu-state` item with a `password` field: a generated passphrase of **at least 16 characters** (minimum required by `pbkdf2`). If it is lost, the encrypted state becomes unreadable and everything has to be imported again.
- [ ] Run `just tofu init cloudflare` and commit `.terraform.lock.hcl`.
- [ ] Import the existing zones with `import` blocks (example in `tofu/cloudflare/main.tf`), until `just tofu plan cloudflare` shows no change.
