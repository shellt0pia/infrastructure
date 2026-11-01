# Network: evaluations and open points

The choices considered and set aside, and what is still to check or watch. The resulting architecture is in [README.md](README.md).

## Rejected options

| Option | Why not |
| --- | --- |
| A virtual IP for the cluster endpoint | It would need a fixed address, against the "everything dynamic" rule. The DNS round-robin `kube-cluster01.shelltopia.net` is kept, `kubectl` may wait for a timeout when a node is down. |
| Cilium `bpf.masquerade` | Its IPv6 support is beta and always uses the GUA as source, even towards ULA destinations. iptables masquerading is used instead ([cluster](../cluster/README.md#cilium)). |
| Link-local address for the IPv6 BGP peer | The router advertisement gateways are link-local, which Cilium cannot use: the peer is the ULA address of OPNsense, written as is. |
| TCP MD5 on the BGP sessions | Cumbersome on FreeBSD. The listen ranges, the prefix lists and the firewall rule are enough on a dedicated subnet. |
| A Talos ingress firewall | OPNsense filters everything entering the nodes subnet. Pod ↔ node isolation comes from the Cilium host firewall ([cluster](../cluster/README.md#network-policies)). |
| GUA addresses in the configs | The prefix may change: it is only used in the `external` LB pool and the matching OPNsense prefix list. |

## Open points

| Topic | Notes |
| --- | --- |
| ECMP on OPNsense | FRR selects every path; the kernel installs them once `net.route.multipath=1` ([BGP](bootstrap.md#4-bgp-frr)). Check that the flows are actually spread across the nodes: FreeBSD picks the next hop from the flow hash of the packet, which depends on the NIC driver. |
| Multi-WAN | With a 4G backup or the Milkywan WireGuard tunnel and `net.route.multipath=1`: OPNsense gateway groups use pf `route-to` rules, unaffected, but the routes OPNsense writes in the kernel table are. After setting up and during a failover test, `netstat -rn \| grep default` and `netstat -rn -f inet6 \| grep default` must show a single line each. Give each gateway its own monitor IP (dpinger host routes). If a duplicate shows up, `net.route.multipath=0` only costs the BGP ECMP. |
| NAS *Pre Init* script | Check that it survives TrueNAS upgrades ([why](README.md#nas-no-asymmetric-path)). |
| ISP prefix change | Follow the [procedure](runbook.md#ipv6-prefix-change). |
| Milkywan WireGuard tunnel (planned) | Stable public IPv4 and IPv6 prefix. The `external` pool, the OPNsense prefix list and the NAT rules will move to it. cloudflare-ddns is then removed and the `A` record of `gateway-external.kube-cluster01.shelltopia.net` becomes static in OpenTofu ([dns](../dns/evaluations.md#open-points)). |
| Cilium `bpf.masquerade` | Reconsider once its IPv6 support is stable and picks the source address per destination (it would bring eBPF host routing). |

