# Network: first configuration

Configuring OPNsense for the cluster before the first boot of the nodes: DHCP, DNS, firewall and BGP, then the network tests after the bootstrap. Architecture: [README.md](README.md). The network is prepared before the first boot, so that the nodes are reachable by name from maintenance mode on.

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kube-cluster01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| All | MAC addresses of the nodes, to reserve their addresses. | [Hardware table](../nodes/README.md#hardware) | Done for kube-01 and kube-03 |
| 4 | Cilium BGP configuration matching the ASNs and the pools, in `kubernetes/apps/kube-system/cilium/networking`. | [cluster/bootstrap.md](../cluster/bootstrap.md#1-git-repository) | Done |

## 1. DHCP and router advertisements

- [x] **Static mappings.** Create a static mapping by MAC address for each node, **outside of the dynamic range**. The IPv4 addresses are not referenced in the repository, they can be changed in OPNsense only.
- [x] **Domain name.** Check that the DHCP server of the interface sends the domain name (`shelltopia.net`).
- [x] **Router advertisements.** Check that the router advertisements of the interface still provide SLAAC for both prefixes (A flag), RDNSS and DNSSL.

## 2. DNS (Unbound, internal only)

- [x] **Node names.** Add host overrides `kube-01` and `kube-03` in `shelltopia.net`: **AAAA records only**, with the ULA address of the [table](README.md#nodes-subnet).
- [x] **Cluster endpoint.** Add host overrides **with the same name** `kube-cluster01.shelltopia.net`, one AAAA record per node (ULA address). This DNS round-robin is the `cluster.endpoint`.
- [x] **Check the endpoint:**

  ```sh
  dig +short AAAA kube-cluster01.shelltopia.net
  ```

  Expected: the ULA addresses of the nodes.

- [x] **Check the NTP server.** `ntp-01.shelltopia.net` (`network.ntp_servers` in `talos/vars.yaml`) resolves from the nodes subnet.
- [x] **Cloudflare.** **Do not** create these records on Cloudflare: the Kubernetes and Talos APIs must stay internal.

The reasons for AAAA records only are in the [README](README.md#names).

## 3. Firewall

- [x] **Administration.** Administration subnets (`fd38:4c4d:8f66:a::/64`, and optionally `192.168.10.0/24` and `2a02:8434:f003:d10a::/64`) → nodes: TCP 50000 (Talos API) and 6443 (Kubernetes API). The names only resolve to ULA addresses, so the ULA rule is the one used.
- [x] **DNS and NTP.** Nodes → OPNsense: DNS (TCP/UDP 53) and NTP (UDP 123, addresses of `ntp-01.shelltopia.net`).
- [x] **Internet.** Nodes → Internet over HTTPS (443), IPv4 and IPv6:
  - images: `factory.talos.dev`, `ghcr.io`, `registry.k8s.io` (and its CDNs), Docker Hub (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`);
  - image signature verification: `tuf-repo-cdn.sigstore.dev` (Sigstore TUF repository). Without it, the images of `registry.k8s.io`, `ghcr.io/siderolabs` and `factory.talos.dev` cannot be pulled;
  - `discovery.talos.dev` and `github.com` (for Flux).
- [x] **Public resolvers.** Nodes → public DNS resolvers of Cloudflare (`1.1.1.1`, `1.0.0.1`, `2606:4700:4700::1111`, `2606:4700:4700::1001`): TCP and UDP 53. cert-manager checks the propagation of its DNS-01 challenges against them (`dns01RecursiveNameservers`), because the internal DNS is split-horizon. The queries come from the pods, masqueraded behind the node addresses.
- [x] **NUT.** Nodes → NUT server (`ups.server` in `talos/vars.yaml`): TCP 3493, if it is not on the nodes subnet. On the NAS, allow the nodes addresses in `upsd.conf`/the NFS exports if they are filtered.
- [x] **Between the nodes.** Everything is on the same subnet, nothing to do. The Talos ingress firewall is not used: OPNsense filters all the traffic entering the nodes subnet. The traffic between the pods and the nodes never goes through it, it is restricted by the Cilium host firewall ([cluster](../cluster/README.md#network-policies)).
- [x] **BGP.** Nodes subnet (`192.168.15.0/24` and `fd38:4c4d:8f66:f::/64`) → *This Firewall*: TCP 179 (BGP, [step 4](#4-bgp-frr)).
- [x] **LoadBalancer pools.** Administration subnets → LoadBalancer pools (internal: `192.168.19.0/25`, `fd38:4c4d:8f66:13::/64` / external: `192.168.19.128/25`, `2a02:8434:f003:d113::/64`): TCP 80 for the test of the [LoadBalancer](#network-tests-after-the-bootstrap). The rules of the Gateways are in [ingress/bootstrap.md](../ingress/bootstrap.md#firewall).

## 4. BGP (FRR)

The design is in the [README](README.md#bgp).

- [x] **Routing service.** In *Routing → General*, enable the routing service.
- [x] **BGP.** In *Routing → BGP → General*, enable BGP, *BGP AS Number* `64512`, *Router ID* `192.168.15.1`. The router ID is optional, but without it FRR picks the highest IPv4 address of OPNsense, possibly the public WAN one: when it changes, every BGP session is reset. It is only an identifier, it does not need to follow a renumbering of the subnet.
- [x] **ECMP.** In the same page, *Max Paths* `3`: with ECMP, the traffic towards an IP advertised by several nodes is spread across them, and another node keeps receiving it within 9 seconds if one fails.
- [x] **Kernel multipath.** In *System → Settings → Tunables*, set `net.route.multipath` to `1`. OPNsense sets it to `0` by default: FRR then selects every path, but the FreeBSD kernel only installs one next hop per route. Restart FRR after the change so that zebra reinstalls its routes.
- [x] **Prefix lists.** In *Routing → BGP → Prefix Lists* (the *Network* field is written as is in the FRR configuration), create:

  | Name | IP version | Seq | Action | Network |
  | --- | --- | --- | --- | --- |
  | `kube-cluster01-lb-v4` | IPv4 | 10 | Permit | `192.168.19.0/24 le 32` |
  | `kube-cluster01-lb-v6` | IPv6 | 10 | Permit | `fd38:4c4d:8f66:13::/64 le 128` |
  | `kube-cluster01-lb-v6` | IPv6 | 20 | Permit | `2a02:8434:f003:d113::/64 le 128` |
  | `deny-all-v4` | IPv4 | 10 | Deny | `any` |
  | `deny-all-v6` | IPv6 | 10 | Deny | `any` |

- [x] **Peer groups.** In *Routing → BGP → Peer Groups*, create the following ones. No neighbor needs to be created.

  | Name | Remote AS | Address family | Listen ranges | Prefix list in | Prefix list out |
  | --- | --- | --- | --- | --- | --- |
  | `kube-cluster01-v4` | `64513` | IPv4 | `192.168.15.0/24` | `kube-cluster01-lb-v4` | `deny-all-v4` |
  | `kube-cluster01-v6` | `64513` | IPv6 | `fd38:4c4d:8f66:f::/64` | `kube-cluster01-lb-v6` | `deny-all-v6` |

- [x] **IPv6 prefix list.** The peer group form only offers one entry of a prefix list (`kube-cluster01-lb-v6:10` or `:20`): pick any of them. The plugin renders the reference by **name** (`neighbor kube-cluster01-v6 prefix-list kube-cluster01-lb-v6 in`), and all the entries sharing this name form a single FRR prefix list. Check:

  ```sh
  vtysh -c 'show running-config'
  ```

  Expected: both `ipv6 prefix-list kube-cluster01-lb-v6 seq 10/20` lines are present.

If the ISP changes the delegated prefix, follow the [runbook](runbook.md#ipv6-prefix-change) (`external` pool in `pools.yaml`, `kube-cluster01-lb-v6` prefix list, firewall rules, DNS).

## Network tests after the bootstrap

To run once the cluster is bootstrapped ([cluster/bootstrap.md](../cluster/bootstrap.md#3-bootstrap)).

- [x] **DNS and egress from a pod.** The first command opens a shell in the pod, run the next ones in it:

  ```sh
  kubectl run nettest --rm -it --restart=Never --image=docker.io/nicolaka/netshoot -- bash
  dig kubernetes.default.svc.cluster.local A +short    # 10.96.0.1
  dig ntp-01.shelltopia.net AAAA +short                # resolved by OPNsense through CoreDNS and the Talos host DNS
  curl -6 https://ifconfig.co                          # GUA address of the node (Internet destination)
  ping -6 -c 3 fd38:4c4d:8f66:f::1                     # OK, masqueraded behind the ULA address of the node
  ```

  Expected: on OPNsense, the states of the last ping show the ULA address of the node as source, not its GUA one.

- [x] **BGP sessions**, from a Cilium agent, then on OPNsense:

  ```sh
  kubectl -n kube-system exec ds/cilium -- cilium-dbg bgp peers
  vtysh -c 'show bgp summary'                          # on OPNsense, or Routing → Diagnostics → BGP
  ```

  Expected: the two sessions of one node (`opnsense-ipv4` with `192.168.15.1`, `opnsense-ipv6` with `fd38:4c4d:8f66:f::1`) are `established`. On OPNsense, one IPv4 and one IPv6 neighbor per node, created dynamically (marked with `*`). No prefix is exchanged yet (`Advertised 0`, `PfxRcd 0`, empty routing tables): the nodes only advertise LoadBalancer IPs, and there is no LoadBalancer Service until the test below.

- [x] **LoadBalancer pools:**

  ```sh
  kubectl get ciliumloadbalancerippools
  ```

  Expected: `internal` and `external`, not `CONFLICTING`.

- [x] **LoadBalancer Service:**

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

  On OPNsense:

  ```sh
  vtysh -c 'show bgp ipv4 unicast'
  vtysh -c 'show bgp ipv6 unicast'
  vtysh -c 'show ip route 192.168.19.1/32'
  netstat -rn | grep 192.168.19
  netstat -rn -f inet6 | grep fd38:4c4d:8f66:13
  ```

  Expected: the /32 and /128 routes, one path per node. `netstat` shows one line per installed next hop: one per node with ECMP (`show ip route` marks every next hop with `*` even when the kernel keeps only one, see `net.route.multipath` above). From the workstation:

  ```sh
  curl http://<IPv4>
  curl 'http://[<ULA>]'
  ```

  Expected: both answer.

- [x] **External pool**, then cleanup:

  ```sh
  kubectl label svc lbtest lbipam.shelltopia.net/pool=external
  kubectl get svc lbtest
  kubectl delete svc,deployment lbtest
  ```

  Expected: the addresses move to `192.168.19.128/25` and `2a02:8434:f003:d113::/64`.
