# IPv6 prefix change

What to update when the ISP delegates a new IPv6 prefix. Current delegated prefix: `2a02:8434:f003:d100::/56`.

Until the Milkywan WireGuard tunnel gives a stable public prefix (see [roadmap.md](roadmap.md)), the GUA prefix can change at any time. Since external IPv6 access is broken anyway until the procedure is done, it does not need to be zero-downtime.

## What does not change

The configuration was designed so that a prefix change has almost no impact:

- the ULA prefix `fd38:4c4d:8f66::/48` and every ULA address: node names, cluster endpoint, etcd, BGP sessions, `internal` LB pool, NAS, NTP, DNS;
- the cluster ranges (`fd1b:654d:9afe::/48`), never routed outside the cluster;
- the subnet IDs: OPNsense keeps the same prefix ID on each interface, only the first 56 bits change.

New GUA prefix of a subnet = first 56 bits of the new delegated prefix + the same subnet ID (2 hex digits, ID `13` in the example below). Example with a new delegated prefix `2001:db8:1234:ab00::/56`:

| Usage | Subnet ID | Current | New |
| --- | --- | --- | --- |
| Administration subnet | `0a` | `2a02:8434:f003:d10a::/64` | `2001:db8:1234:ab0a::/64` |
| Nodes subnet | `0f` | `2a02:8434:f003:d10f::/64` | `2001:db8:1234:ab0f::/64` |
| `external` LB pool | `13` | `2a02:8434:f003:d113::/64` | `2001:db8:1234:ab13::/64` |

If the ISP ever delegates a smaller prefix (e.g. a /60, with subnet IDs `0` to `f` only), subnet ID `13` no longer fits: pick a new ID for the `external` pool and update the documentation accordingly.

## Automatic (nothing to do)

| Where | Why |
| --- | --- |
| OPNsense interfaces and router advertisements | Interfaces track the WAN delegated prefix (DHCPv6-PD). |
| OPNsense *Dynamic IPv6 Host* aliases | The interface identifier is combined with the current prefix of the interface. |
| Talos nodes | SLAAC: the new GUA address shows up, the old one expires (its lifetime, or earlier if OPNsense deprecates the old prefix). The machine configs never reference the GUA (`nodeIP` and etcd use IPv4 and ULA only). |
| Kubernetes | Node IPs are IPv4 and ULA. Pod egress to the Internet is masqueraded by iptables, the kernel picks the new GUA as source address. |
| Cilium BGP sessions | Between ULA addresses. |
| NAS | Static ULA on the nodes subnet, SLAAC on its main interface. |

## Manual

Order matters: let OPNsense accept the new routes **before** the cluster advertises them.

### 1. OPNsense: BGP prefix list

*Routing → BGP → Prefix Lists*:

- [ ] `kube-cluster01-lb-v6`, seq `20`: replace the network with `<new external pool /64> le 128`.
- [ ] Apply, then check: `vtysh -c 'show running-config' | grep kube-cluster01-lb-v6`.

### 2. Repository: `external` LB pool

- [ ] `kubernetes/apps/kube-system/cilium/networking/pools.yaml`: replace the GUA block of the `external` pool.
- [ ] If a Service pins its address with the `lbipam.cilium.io/ips` annotation (e.g. a Gateway), update it too: `git grep 'lbipam.cilium.io/ips'`.
- [ ] Commit, push, then `flux reconcile kustomization cilium-networking -n kube-system --with-source`.
- [ ] Check that the pool is not `CONFLICTING` (`kubectl get ciliumloadbalancerippools`) and that the external Services got a new IPv6 address from the new prefix:

  ```sh
  kubectl get svc -A -l lbipam.shelltopia.net/pool=external
  ```

  If a Service keeps its old address, remove the address from its status or recreate it.

- [ ] On OPNsense, `vtysh -c 'show bgp ipv6 unicast'`: the /128 routes of the new prefix, the old ones are gone.

### 3. OPNsense: firewall and NAT

- [ ] WAN rules allowing inbound IPv6 to the `external` pool (or to its addresses).
- [ ] Rule *Administration subnets → LoadBalancer pools* (phase 3 of [first-bootstrap.md](first-bootstrap.md)).
- [ ] Any rule or alias written with a GUA network instead of an interface network macro (`<interface> net`) or a *Dynamic IPv6 Host* alias. To find them: search for the old prefix in *System → Configuration → Backups* (download the XML).

### 4. DNS

- [ ] Cloudflare: AAAA records of the public names pointing to the `external` pool. With OpenTofu: update the addresses in `tofu/cloudflare`, then `just tofu plan cloudflare` and `just tofu apply cloudflare`. Not needed for records managed by external-dns, if it is deployed by then: they follow the Service status.
- [ ] Unbound: host overrides with a GUA address, if any (the node names and internal services use ULA addresses).

### 5. Elsewhere

- [ ] `home` and the other Ansible-managed hosts, while they still exist: the production inventory is encrypted, check it for the old prefix (`ansible-vault view`).
- [ ] Third-party allowlists filtering on your IPv6 addresses (if any).
- [ ] Documentation: `git grep 2a02:8434` lists the remaining examples (`docs/first-bootstrap.md`, `docs/roadmap.md`, this file), update them for consistency.

## Final checks

- [ ] `talosctl get addresses`: the new GUA address on every node.
- [ ] From a pod: `curl -6 https://ifconfig.co` returns the new GUA address of its node.
- [ ] From outside (e.g. mobile network): the public services answer over IPv6.

## Reducing the work

- Use a single OPNsense *Network* alias for the `external` pool in every rule: one place to change instead of every rule.
- Manage the public records with external-dns: the DNS step disappears.
- Do not pin GUA addresses on Services (`lbipam.cilium.io/ips`) unless needed.
- Once the Milkywan tunnel is in place, the `external` pool moves to its stable prefix and this procedure no longer applies to it.
