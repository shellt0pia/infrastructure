# Network: Milkywan WireGuard tunnel

Plan to configure the Milkywan tunnel (WireGuard, dedicated public IPv4, routed IPv6 /48) on OPNsense, then to move the nodes subnet and the `external` pool to it. Architecture: [README.md](README.md). The checkboxes track the work.

## Addressing

| Item | Value |
| --- | --- |
| Endpoint | `wg-cust-lyn.milkywan.cloud:52103` |
| Device | `wg2` (`WG_MilkyWan`, `opt11`) |
| Tunnel IPv4 | `10.1.6.20/30`: Milkywan `10.1.6.21`, OPNsense `10.1.6.22` |
| Tunnel IPv6 | `2a0b:cbc0:7:1::c/126`: Milkywan `2a0b:cbc0:7:1::d`, OPNsense `2a0b:cbc0:7:1::e` |
| Routed IPv4 | `45.13.104.160` |
| Routed IPv6 | `2a0e:e701:2132::/48` |
| Nodes subnet GUA (proposed) | `2a0e:e701:2132:f::/64` (same subnet ID as the ULA one) |
| `external` pool GUA (proposed) | `2a0e:e701:2132:13::/64` (same subnet ID as the ULA `internal` pool) |

The interconnect addresses are only for the WireGuard tunnel itself. Milkywan routes the public IPv4 and the /48 to OPNsense through it, and **the traffic towards the Internet must use the routed IPv4** (not the interconnect one) as source.

## Decisions

- **No BGP with Milkywan.** The basic offer routes the IPv4 and the /48 **statically** to the tunnel. The eBGP delivery is only available when ordering two compatible services (redundancy), which the support confirmed. The only BGP of OPNsense stays the one of the cluster ([BGP](README.md#bgp)): the FRR plugin has a single BGP instance (AS `64512`), the *Router ID* stays `192.168.15.1`, FRR is not touched. If a second tunnel is ordered one day, decide then whether AS `64512` is reused or a distinct private AS is needed.
- **Only the nodes subnet uses the tunnel.** The other subnets keep the fibre (WAN) and the ISP prefix. The tunnel is not the default gateway: only the Internet traffic of the nodes subnet is sent to it, by firewall rules with a gateway (policy routing).
- **Nodes addressing: nothing to renumber.**
  - IPv4 stays `192.168.15.0/24` and the ULA `fd38:4c4d:8f66:f::/64`. They are translated or unused towards the Internet, and every internal flow (BGP, names, etcd, administration) is unchanged.
  - IPv4 is translated to `45.13.104.160` on `wg2`. It is a routed address, not an interface one: it is an IP alias of `wg2`.
  - IPv6: OPNsense advertises a **Milkywan /64 on the nodes subnet instead of the ISP GUA one** (`2a02:8434:f003:d10f::/64`). The nodes then get a Milkywan GUA by SLAAC, no NAT66. Do not advertise both: the nodes pick the source address themselves, and an ISP-sourced packet sent through the tunnel is dropped by Milkywan (and the opposite is by the ISP).
- **The /48 is routed to OPNsense, not assigned as a whole.** Only the /64 of the nodes subnet is an interface address. The `external` pool /64 is only routed through BGP, like every LoadBalancer prefix ([BGP](README.md#bgp)): **never assign it to an interface**.
- **MSS per interface.** The MSS of the tunnel is set on its own interface, not through a *Normalization* rule on the whole WireGuard group: the right value depends on the MTU of each tunnel, hence on its path (the other WireGuard instance serves the remote access clients).
- **Ingress IPv4: HAProxy stays.** `home` (the future kube-02) is also on the nodes subnet, so it goes through the tunnel too: `45.13.104.160` is shared by `home` and the cluster, and HAProxy keeps routing on the SNI and the Host header ([ingress](../ingress/README.md#ipv4-from-the-internet)). It only listens on `45.13.104.160` instead of the WAN address. The WAN IPv4 no longer receives any ingress traffic once the DNS has moved. The port forwarding that replaces HAProxy ([removing HAProxy](../ingress/runbook.md#removing-haproxy)) stays for when `home` no longer serves any name.
- **If the tunnel is down, the nodes have no Internet** (images, Flux, DNS-01 challenges). A fallback through the WAN is only possible in IPv4 (NAT to the WAN address), not in IPv6 (the ISP drops the Milkywan prefix). The 4G backup planned for later carries the tunnel itself.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | Peer public key. | Milkywan *Univers* | To do |
| 1 | `wg2` device and its interface `WG_MilkyWan` (`opt11`). | [Addressing](#addressing) | Created |
| 4 | How the nodes interface gets its IPv6 prefixes (the ISP one tracked, the ULA one static or alias), to do the same for the Milkywan /64. | *Interfaces* of the nodes subnet, *Services → Router Advertisements* | To do |

## 1. WireGuard tunnel

In *VPN → WireGuard*:

- [x] **Instance.** Private key (OPNsense derives the public one). *Tunnel Address*: `10.1.6.22/30` and `2a0b:cbc0:7:1::e/126` (never a /32 or a /128). *DNS* empty, otherwise WireGuard overwrites the DNS configuration of OPNsense. *MTU* empty (1420). **Disable Routes** checked: the routes to the *Allowed IPs* are not created, the routing is done by [step 3](#3-routing).
- [x] **Peer.** Public key of Milkywan, endpoint `wg-cust-lyn.milkywan.cloud` port `52103`, *Keepalive* `25`, *Allowed IPs* `0.0.0.0/0` and `::/0`. Traffic outside the *Allowed IPs* is dropped silently, which is why wide values are fine when the routes are disabled.
- [x] **Interface.** In *Interfaces → Assignments*, `wg2` is assigned (*Enable*, *Lock*), IPv4 and IPv6 configuration types **None** (the addresses come from the instance, `ifconfig wg2` shows `10.1.6.22/30` and `2a0b:cbc0:7:1::e/126`). *MSS* `1420`.
- [x] **Check the MSS:**

  ```sh
  grep -i mss /tmp/rules.debug
  ```

  Expected: `scrub on wg2 inet all max-mss 1380` and `scrub on wg2 inet6 all max-mss 1360`. The interface MSS minus 40 (IPv4) or 60 (IPv6), which is why the two values differ. Do not add a *Normalization* rule too.
- [x] **WAN address for the handshake.** The endpoint resolves to an IPv6 address (`AAAA`). The WAN has only a link-local address (DHCPv6-PD, no address from the ISP), so the kernel picks the source of the handshake among the other global addresses of the firewall: the longest common prefix wins, which is the tunnel address `2a0b:cbc0:7:1::e`. The packets leave through the WAN with this source, Milkywan ignores them and the tunnel never comes up (it can work at one boot and not at the next, depending on which addresses exist when WireGuard starts). Give the WAN a global address, which the kernel prefers (outgoing interface): in the advanced DHCPv6 client configuration of the WAN, set an unused *Optional prefix ID* (e.g. `ff`, not the one of another interface) and an *Optional interface ID* (e.g. `1`). The WAN then gets an address of the delegated prefix (`<prefix>:d1ff::1` for `ff`), which follows the prefix when the ISP changes it. Do not use that /64 anywhere else. Check:

  ```sh
  ifconfig igc0 | grep inet6
  tcpdump -ni igc0 udp port 52103
  ```

  Expected: a global address on the WAN, and the source of the handshake is this address (not `2a0b:cbc0:7:1::e`). Keep the hostname as the endpoint: it does not need to be an IPv4 address.
- [x] **Handshake.** *VPN → WireGuard → Status* shows a recent handshake, otherwise the log. An inbound WAN rule is not needed (the firewall initiates the connection); add one (UDP to the listen port, from the endpoint) only if the handshake fails.

When a 4G backup carries the tunnel, test the path MTU through it (ping with the DF bit, decreasing sizes, with the traffic forced through the 4G). If 1420 does not fit, lower the *MTU* of the instance and the *MSS* of the interface to its value minus 40 and 60 (the single setting must suit the narrowest path). The same source address problem applies to the 4G interface: give it a global address too, or the handshake over IPv6 will leave with the tunnel address.

## 2. Gateways and routed addresses

- [x] **Gateways.** In *System → Gateways → Configuration*, one IPv4 gateway (`10.1.6.21`) and one IPv6 gateway (`2a0b:cbc0:7:1::d`) on `wg2`, **not** marked as the default gateway. Give each its own monitor IP (dpinger adds a host route for it).
- [x] **Check the default routes** (see [multi-WAN](evaluations.md#open-points)):

  ```sh
  netstat -rn | grep default
  netstat -rn -f inet6 | grep default
  ```

  Expected: a single line each, the WAN one. `net.route.multipath=1` is set for the BGP ECMP, and a duplicate default route would break the egress. If one shows up, `net.route.multipath=0` only costs the ECMP. Repeat during a failover test once the 4G backup is in place.
- [x] **Routed IPv4.** In *Firewall → Virtual IPs*, an *IP Alias* `45.13.104.160/32` on `WG_MilkyWan`.

## 3. Routing

- [x] **Egress.** In the rules of the nodes subnet that allow the Internet ([firewall](bootstrap.md#3-firewall): HTTPS, public resolvers), set the gateway of the tunnel, IPv4 and IPv6 (one rule per family: a gateway or gateway group is IPv4 or IPv6, not both, so an IPv4+IPv6 rule cannot carry a gateway; the rules without a gateway can stay IPv4+IPv6, with aliases holding both families). The gateway only applies in the direction of the rule, and the rules to the internal destinations (DNS, NTP, administration, BGP) keep no gateway.
- [x] **Return path.** The replies to the traffic that came in through `wg2` (to the firewall itself, or forwarded to the nodes by a port forward) must go back through it: the system routing table sends them to the WAN with a source that is not the WAN address, and the ISP drops them. `reply-to` is only automatic when OPNsense knows a gateway of the interface, which is not a given for an interface of type **None**. Do not rely on it: set the **Reply-to** field of every inbound rule of [step 4](#4-firewall-and-nat) to the gateway of the family of the rule (so one rule per family, never IPv4+IPv6), and check it in `/tmp/rules.debug` (`reply-to ( wg2 10.1.6.21 )`) and with `tcpdump -ni wg2`.
- [x] **No route for the /48.** The nodes subnet /64 is on-link, the pool prefixes are learned from the nodes as /32 and /128 routes through BGP ([BGP](README.md#bgp)).

## 4. Firewall and NAT

- [x] **BGP rule.** Nothing to do, the rule of the nodes subnet already exists ([firewall](bootstrap.md#3-firewall)).
- [x] **Outbound NAT.** The *Source NAT* rule `source WG_MilkyWan → interface address` that OPNsense creates when the interface is assigned matches the sources of the tunnel network only, and would translate to the interconnect address: leave it aside. Switch *Firewall → NAT → Outbound* to **Hybrid** and add a rule on `WG_MilkyWan`, source `192.168.15.0/24`, translated to `45.13.104.160` (the alias). No NAT for IPv6.
- [x] **Nodes subnet IPv6.** Give the interface of the nodes subnet the address `2a0e:e701:2132:f::1/64`, advertise this prefix in the router advertisements (SLAAC, like the ULA one) and stop advertising the ISP one. The nodes get a new address with the same interface identifier ([nodes](README.md#nodes-subnet)).
- [x] **Inbound rules.** On `wg2`: TCP 80 and 443 to the `external` Gateway, over IPv6 (its address in the `external` pool /64) and over IPv4 to `45.13.104.160` (HAProxy listening on the alias, [step 5](#5-move-the-nodes-subnet-and-the-external-pool)). **8080 and 8443 are never exposed**, they only receive the PROXY protocol from HAProxy.

## 5. Move the nodes subnet and the `external` pool

Once the tunnel works (outbound and inbound, IPv4 and IPv6, from a test host using the public addresses):

- [x] **Pool.** `kubernetes/apps/kube-system/cilium/networking/pools.yaml`: the GUA part of the `external` pool is `2a0e:e701:2132:13::/64`.
- [x] **Pinned addresses.** No Service of the `external` pool pins its addresses yet (still dynamic): only [reference.md](../reference.md#pinned-loadbalancer-addresses) is updated, with the expected address (to check after the deployment).
- [x] **Network policy.** `kubernetes/apps/kube-system/cilium/policies/baseline.yaml`: add `2a0e:e701:2132::/48` to the `::/0 except` list, next to the delegated /56. Otherwise the pods reach the GUA addresses of the other nodes as `world`. Keep the /56: the other subnets still use it.
- [x] **Prefix list.** `kube-cluster01-lb-v6` seq 20: `2a0e:e701:2132:13::/64 le 128` instead of `2a02:8434:f003:d113::/64 le 128` ([BGP](bootstrap.md#4-bgp-frr)).
- [x] **HAProxy.** The `http` and `https` frontends listen on `45.13.104.160` (ports 80 and 443) instead of the WAN address. The backends (`home`, the `external` Gateway with the PROXY protocol) are unchanged. Firewall rule on `wg2`: TCP 80 and 443 → `45.13.104.160` (This Firewall), IPv4, **Reply-to** `10.1.6.21`. The alias must exist when HAProxy starts: restart the firewall once and check that HAProxy is listening (`sockstat -4l | grep haproxy`), otherwise restart it once the tunnel is up.
- [x] **Other ports of `home`.** Every other service of `home` published on the WAN (port forwardings) is recreated on `wg2` (destination `45.13.104.160`, with its rule and its Reply-to).
- [x] **WAN.** Once the DNS has moved and its TTL has expired, remove the WAN rules of HAProxy (80 and 443) and the old port forwardings.
- [x] **Firewall.** The ingress rule of the external pool IPv6, now on `wg2` ([ingress](../ingress/bootstrap.md#firewall)).
- [ ] **DNS.** Make the `A` record of `gateway-external.kube-cluster01.shelltopia.net` static (`45.13.104.160`) in OpenTofu (`tofu/cloudflare`) and point the `A` records of the names of `home` to it too (find out what updates them today). Remove `cloudflare-ddns` (`kubernetes/apps/network/cloudflare-ddns`) once nothing else depends on the WAN address, see [dns](../dns/evaluations.md#open-points). Set the reverse DNS in *Univers*.
- [ ] **Documentation.** The Milkywan tunnel is no longer "planned" (done, except the DNS documents, which follow the DNS step): [README](README.md#status), [evaluations](evaluations.md#open-points), [runbook](runbook.md#ipv6-prefix-change), [roadmap](../roadmap.md#to-check-or-watch) and [ingress](../ingress/README.md#overview). Once the DNS has moved: [dns](../dns/README.md).

## 6. Tests

- [x] **Tunnel.** From OPNsense, ping the peers (`10.1.6.21`, `2a0b:cbc0:7:1::d`), then an Internet host with the source set to `45.13.104.160` and to an address of the /48 (`ping -S`).
- [x] **Path MTU.** Ping with the DF bit through the tunnel, the largest size that passes matches the MTU. From `home`: `ping -4 -M do -s 1392 www.google.com` passes and `-s 1393` gets `Frag needed (mtu = 1420)`, `ping -6 -M do -s 1372` passes and `-s 1373` fails (1420 bytes on both families, the WAN carries 1500 bytes of WireGuard over IPv6). Repeat with the 4G backup.
- [ ] **MSS.** The SYN and SYN-ACK packets **leaving** through `wg2` carry 1380 (IPv4) and 1360 (IPv6) (`tcpdump -ni wg2 'tcp[tcpflags] & tcp-syn != 0'`). The incoming ones are captured before `pf` and show the value of the remote end (e.g. 1460): ignore them. Check that no packet leaves larger than the MTU for an inbound connection (`tcpdump -ni wg2 'tcp src port 443 and ip[2:2] > 1420'`, with a large download from outside). IPv4 checked on 2026-11-04, IPv6 to do.
- [x] **Nodes egress.** From a pod, as in the [network tests](bootstrap.md#network-tests-after-the-bootstrap): `curl -4 https://ifconfig.co` shows `45.13.104.160`, `curl -6` an address of `2a0e:e701:2132:f::/64`.
- [x] **Other subnets.** A LAN host still shows the WAN address and the ISP prefix.
- [ ] **Ingress.** From outside (a phone on 4G): `https://gateway-external.kube-cluster01.shelltopia.net` over IPv4 and over IPv6. In the states of OPNsense, the replies leave through `wg2`.
- [x] **BGP.** `vtysh -c 'show bgp ipv6 unicast'` lists the new /64 or /128 from the nodes, and nothing is exchanged with Milkywan.
