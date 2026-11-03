# Reference

The names, addresses, ports, namespaces, items and schedules scattered in the topics, in one place. Each table says where the thing is described: that document is the one to update, this page only collects it.

## Domains and names

| Name | Use | Described in |
| --- | --- | --- |
| `shelltopia.org` | The services: every application name, served by the wildcard certificate `*.shelltopia.org` | [ingress](ingress/README.md#certificate) |
| `shelltopia.net` | The infrastructure: nodes, firewall, NAS, NTP, UPS | [network](network/README.md#nodes-subnet) |
| `kube-01`, `kube-02`, `kube-03` (`.shelltopia.net`) | The nodes, A and AAAA records (IPv4 and ULA addresses) with their PTR | [network](network/README.md#names) |
| `kube-cluster01.shelltopia.net` | The cluster endpoint: DNS round-robin, one AAAA per node, API on port 6443 | [network](network/README.md#principles) |
| `gateway-external.kube-cluster01.shelltopia.net` | Entry name of the external Gateway, target of the public CNAMEs | [dns](dns/README.md#public-external-dns-and-cloudflare-ddns) |
| `syslog.kube-cluster01.shelltopia.net` | The Vector aggregator: Talos logs and syslog of the devices. Unbound host overrides, `A` and `AAAA` to its pinned addresses | [observability](observability/README.md#logs) |
| `graphite.kube-cluster01.shelltopia.net` | The Graphite listener of `VMAgent` (reserved: the TrueNAS exporter takes an IP only). Unbound host overrides, `A` and `AAAA` to its pinned addresses | [observability](observability/README.md#metrics) |
| `ntp-01.shelltopia.net`, `ups-01-dmz.shelltopia.net` | NTP (OPNsense) and NUT server (the NAS) of the nodes | [network](network/README.md#principles) |

## Addresses

| What | IPv4 | IPv6 | Described in |
| --- | --- | --- | --- |
| Nodes subnet | `192.168.15.0/24` | `fd38:4c4d:8f66:f::/64` (ULA), `2a0e:e701:2132:f::/64` (GUA, Milkywan /48) | [network](network/README.md#nodes-subnet) |
| `kube-01`, `kube-02`, `kube-03` | `192.168.15.11`, `.12`, `.13` | EUI-64 ULA addresses, in the table of the nodes subnet | [network](network/README.md#nodes-subnet) |
| `internal` LB pool | `192.168.19.0/25` | `fd38:4c4d:8f66:13::/64` | [network](network/README.md#bgp) |
| `external` LB pool | `192.168.19.128/25` | `2a0e:e701:2132:13::/64` (GUA, Milkywan /48) | [network](network/README.md#bgp) |
| Milkywan WireGuard tunnel (`wg2`) | `10.1.6.20/30`, routed `45.13.104.160` | `2a0b:cbc0:7:1::c/126`, routed `2a0e:e701:2132::/48` | [network](network/milkywan.md) |
| Pods | `10.244.0.0/16` | `fd1b:654d:9afe:100::/56` | [cluster](cluster/README.md#cluster-ranges) |
| Services | `10.96.0.0/12` | `fd1b:654d:9afe:200::/112` | [cluster](cluster/README.md#cluster-ranges) |
| Cluster DNS | `10.96.0.10` | `fd1b:654d:9afe:200::a` | [cluster](cluster/README.md#coredns) |
| NAS main interface | `192.168.14.0/24` | | [network](network/README.md#nas-no-asymmetric-path) |

The cluster ranges and the Milkywan /48 are permanent, the ISP GUA prefix of the LAN may change: [what to update](network/runbook.md#ipv6-prefix-change).

BGP: OPNsense is AS `64512`, the nodes share AS `64513` ([network](network/README.md#bgp)).

### Pinned LoadBalancer addresses

Every LoadBalancer Service pins its addresses (`lbipam.cilium.io/ips`), allocated here first ([conventions](conventions.md#loadbalancer-addresses)). The same host part in both families.

| Service | Pool | IPv4 | IPv6 | Depends on it | Described in |
| --- | --- | --- | --- | --- | --- |
| Envoy, `internal` Gateway | `internal` | `192.168.19.1` | `fd38:4c4d:8f66:13::1` | The names of the applications (k8s-gateway), the OPNsense rules of the clients. Still dynamic, [to pin](roadmap.md#ingress) | [ingress](ingress/README.md#overview) |
| Vector aggregator (`syslog`) | `internal` | `192.168.19.2` | `fd38:4c4d:8f66:13::2` | Host overrides `syslog.kube-cluster01.shelltopia.net`, the OPNsense rules of the device VLANs | [observability](observability/README.md#logs) |
| Graphite of `VMAgent` | `internal` | `192.168.19.3` | `fd38:4c4d:8f66:13::3` | Host overrides `graphite.kube-cluster01.shelltopia.net`, the TrueNAS exporter (by IP), the OPNsense rules | [observability](observability/README.md#metrics) |
| k8s-gateway | `internal` | `192.168.19.53` | `fd38:4c4d:8f66:13::53` | The Unbound query forwarding of `shelltopia.org` | [dns](dns/README.md#internal-k8s-gateway) |
| Envoy, `external` Gateway | `external` | `192.168.19.129` | `2a0e:e701:2132:13::1` (GUA, expected, to check once the pool is applied) | The HAProxy backends, the `wg2` rules of OPNsense. Still dynamic (IPv4 checked on 2026-11-02), [to pin](roadmap.md#ingress) | [ingress](ingress/README.md#overview) |

## Ports

| Port | From, to | Described in |
| --- | --- | --- |
| TCP 50000 (Talos API), 6443 (Kubernetes API) | Administration subnets → nodes | [network](network/bootstrap.md#3-firewall) |
| TCP and UDP 53, UDP 123 | Nodes → OPNsense (DNS, NTP) | [network](network/bootstrap.md#3-firewall) |
| TCP and UDP 53 | Nodes → public resolvers of Cloudflare (DNS-01 checks of cert-manager) | [network](network/bootstrap.md#3-firewall) |
| TCP 3493 | Nodes → NUT server | [network](network/bootstrap.md#3-firewall) |
| TCP 179 | Nodes → OPNsense (BGP) | [network](network/bootstrap.md#3-firewall) |
| TCP 80 and 443, UDP 443 (internal Gateway only) | Clients → Gateways | [ingress](ingress/README.md#overview) |
| TCP 8080 and 8443 | HAProxy → external Gateway (PROXY protocol, until `home` is migrated) | [ingress](ingress/README.md#ipv4-from-the-internet) |
| TCP and UDP 53 | Unbound → k8s-gateway | [dns](dns/README.md#internal-k8s-gateway) |
| TCP 3366 (LINSTOR satellite), 7000-7999 (DRBD), 9942 (drbd-reactor metrics) | Between the nodes | [storage](storage/README.md#decisions) |
| TCP 30020 (NodePort), TCP and UDP 5001 (libp2p) | Node → local Spegel, Spegel → Spegel | [cluster](cluster/README.md#spegel) |
| TCP 6443, TCP and UDP 53 (Talos host DNS) | Pods → nodes, the only node ports open to every pod (host firewall) | [cluster](cluster/README.md#network-policies) |
| TCP 3366 | LINSTOR controller pod → satellites (host network) | [cluster](cluster/README.md#network-policies) |
| TCP 4244 | Hubble Relay → Hubble server of each Cilium agent | [cluster](cluster/README.md#network-policies) |
| TCP 4245 | Workstation → Hubble Relay, through `kubectl port-forward` (`hubble -P`) | [cluster](cluster/runbook.md#network-policies) |
| TCP 10250 (kubelet), 2381 (etcd), 10259 (scheduler), 10257 (controller-manager), 9100 (node-exporter), 9962 (Cilium agent), 9963 (Cilium operator), 9965 (Hubble), 9942 (drbd-reactor) | `VMAgent` → nodes (host firewall) | [observability](observability/README.md#network-and-pod-security) |
| TCP and UDP 514 (to the pod port 5514): syslog. TCP 6050: Talos kernel logs. TCP 6051: Talos service logs | Devices and nodes → Vector aggregator (`syslog.kube-cluster01.shelltopia.net`) | [observability](observability/README.md#logs) |
| Graphite, chosen at stage 5 | TrueNAS → `VMAgent` (`graphite.kube-cluster01.shelltopia.net`) | [observability](observability/README.md#metrics) |

## Namespaces

Every namespace of `kubernetes/apps` has `kustomize.toolkit.fluxcd.io/prune: disabled`, so that a refactoring never deletes it with its content, and includes the `network-policies` component, which allows the traffic between its pods, and the `flux-alerts` component, which sends the failed reconciliations of its Flux objects to the Alertmanager ([conventions](conventions.md#namespaces)). `kube-system` is created by Kubernetes and not managed there. [Pod Security](cluster/README.md#pod-security) is `restricted` by default: only the namespaces at a lower level carry labels.

| Namespace | Content | Pod Security | Described in |
| --- | --- | --- | --- |
| `flux-system` | flux-operator, flux-instance | `restricted` | [cluster](cluster/README.md#decisions) |
| `external-secrets` | External Secrets Operator, the `onepassword` ClusterSecretStore | `restricted` | [secrets](secrets/README.md#in-the-cluster-external-secrets) |
| `cert-manager` | cert-manager, the `ClusterIssuer`s | `restricted` | [ingress](ingress/README.md#certificate) |
| `envoy-gateway-system` | Envoy Gateway | `restricted` | [ingress](ingress/README.md#envoy-gateway) |
| `network` | The Gateways, the wildcard certificate, k8s-gateway, external-dns, cloudflare-ddns | `restricted` | [ingress](ingress/README.md), [dns](dns/README.md) |
| `piraeus-datastore` | Piraeus/LINSTOR | `privileged` | [storage](storage/README.md#decisions) |
| `backups` | VolSync, `volsync-monitor` | `restricted` | [backups](backups/README.md) |
| `observability` | `victoria-metrics-k8s-stack` (operator, `VMSingle`, `VLSingle`, `VMAgent`, `VMAlert`, `VMAlertmanager`, kube-state-metrics), Grafana, `prometheus-operator-crds`, the Vector aggregator. Deployed by stage ([status](observability/README.md#status)) | `restricted` | [observability](observability/README.md#network-and-pod-security) |
| `observability-agents` | node-exporter (from the stack), the Vector agent | `privileged` | [observability](observability/README.md#network-and-pod-security) |
| `debug` | Throwaway test pods, `kubectl debug node` | `privileged` | [cluster](cluster/README.md#pod-security) |
| `kube-system` | Cilium, CoreDNS, Intel device plugin, Reloader, snapshot-controller, Spegel | exempt | [cluster](cluster/README.md) |

A namespace whose applications are exposed on the internet carries the label `shelltopia.net/gateway-external: "true"` ([ingress](ingress/runbook.md#exposing-an-application)).

## 1Password items

| Vault | Item | Used by | Described in |
| --- | --- | --- | --- |
| `infrastructure` | `talos-secrets` | Talos secrets bundle, the PKI of the cluster | [secrets](secrets/bootstrap.md#2-talos-secrets) |
| `infrastructure` | `docker-hub-kube-cluster01` | containerd of the nodes (rate limit) | [secrets](secrets/bootstrap.md#3-docker-hub) |
| `infrastructure` | `nas-01-nut-server` | NUT client of the nodes | [secrets](secrets/bootstrap.md#4-nut) |
| `infrastructure` | `tofu-state-encryption`, `backblaze-b2-tofu-state`, `backblaze-b2-tofu-admin`, `cloudflare-tofu` | OpenTofu | [tofu/README.md](../tofu/README.md) |
| `infrastructure` | `restic-nas` | Backrest on the NAS, never synced to the cluster | [backups](backups/README.md#destination-backblaze-b2) |
| `kubernetes` | `1password-external-secrets-operator` | Token of the store, injected by the bootstrap | [secrets](secrets/bootstrap.md#5-service-account-for-external-secrets) |
| `kubernetes` | `cloudflare-cert-manager`, `cloudflare-external-dns`, `cloudflare-ddns` | cert-manager, external-dns, cloudflare-ddns (field `credential`) | [ingress](ingress/README.md#certificate), [dns](dns/README.md#public-external-dns-and-cloudflare-ddns) |
| `kubernetes` | `restic-volsync` | VolSync | [backups](backups/README.md#destination-backblaze-b2) |
| `kubernetes` | `healthchecks` | Ping URLs of the checks, one field per check: the backups, the dead man's switch of Alertmanager (`kube-cluster01-alertmanager`) | [backups](backups/README.md#monitoring), [observability](observability/README.md#alerting) |
| `kubernetes` | `pushover-alertmanager` | Alertmanager (field `username`: the Pushover user key, `credential`: the application token) | [observability](observability/README.md#alerting) |
| `kubernetes` | `pocket-id-grafana` | Grafana, OIDC client of the Pocket ID (`username`: the client id, `credential`: the secret) | [observability](observability/README.md#grafana) |
| `kubernetes` | `backblaze-b2-cnpg` | CloudNativePG, later | [backups](backups/README.md#destination-backblaze-b2) |
| `personal` | Token of the workstation service account | The shell of the workstation | [secrets](secrets/README.md#on-the-workstation-a-read-only-service-account) |

The tokens to renew and their consumers are in the [secrets runbook](secrets/runbook.md#tokens-to-renew). The naming of the items is in [secrets](secrets/README.md#naming-of-the-items).

## External services

| Service | Use | Described in |
| --- | --- | --- |
| Backblaze B2 | Backups (VolSync, Backrest) and the OpenTofu states | [backups](backups/README.md#destination-backblaze-b2), [tofu/README.md](../tofu/README.md) |
| Cloudflare | DNS and DNSSEC of both zones, DNS-01 challenges | [dns](dns/README.md), [ingress](ingress/README.md#certificate) |
| Let's Encrypt | The wildcard certificate, staging and production | [ingress](ingress/README.md#certificate) |
| 1Password | Every secret | [secrets](secrets/README.md) |
| healthchecks.io | Checks of the backups, dead man's switch of Alertmanager | [backups](backups/README.md#monitoring), [observability](observability/README.md#alerting) |
| Pushover | Notifications of Alertmanager | [observability](observability/README.md#alerting) |
| Pocket ID (PikaPods) | OIDC login of Grafana, later | [observability](observability/README.md#grafana) |
| GitHub | The repository followed by Flux | [cluster](cluster/README.md#decisions) |
| Docker Hub | Pulls through the credentials of containerd | [secrets](secrets/bootstrap.md#3-docker-hub) |

## Schedules

| When | What | Described in |
| --- | --- | --- |
| Every minute | external-dns | [dns](dns/README.md#public-external-dns-and-cloudflare-ddns) |
| Every minute | The `Watchdog` alert pings healthchecks.io (grace 3 minutes), once the rules run | [observability](observability/README.md#alerting) |
| Every 5 minutes | cloudflare-ddns detects the WAN IPv4 | [dns](dns/README.md#public-external-dns-and-cloudflare-ddns) |
| Every hour | Refresh of the ExternalSecrets of the Cloudflare tokens, reconciliation of the Kustomizations and HelmReleases | [conventions](conventions.md#flux-kustomizations) |
| Every 12 hours | Refresh of the ExternalSecrets of VolSync and of its monitoring | [backups](backups/runbook.md#refreshing-the-secrets) |
| Daily, 01:30 UTC | VolSync backups, by default | [backups](backups/README.md) |
| Daily, 09:00 | `volsync-monitor`, then the ping of its healthchecks check | [backups](backups/README.md#monitoring) |
| Every 7 days | VolSync prune | [backups](backups/README.md) |
| Every 30 days | Rotation of the workstation token | [secrets](secrets/runbook.md#rotating-the-workstation-token) |
