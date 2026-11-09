# Network: runbook

Day-to-day administration of the network. Architecture: [README.md](README.md).

## IPv6 prefix change

What to update when the ISP delegates a new IPv6 prefix. Current delegated prefix: `2a02:8434:f003:d100::/56`.

The ISP prefix can change at any time, but it now only concerns the LAN subnets. The nodes subnet and the `external` LB pool use the stable Milkywan /48 (`2a0e:e701:2132::/48`, [milkywan.md](milkywan.md)): neither the cluster nor the nodes follow the ISP prefix anymore. Since external IPv6 access of the LAN is broken anyway until the procedure is done, it does not need to be zero-downtime.

### What does not change

The [configuration](README.md#what-does-not-change-with-a-new-prefix) was designed so that a prefix change has almost no impact: the ULA prefix and every ULA address, the cluster ranges, the Milkywan /48 and the subnet IDs (OPNsense keeps the same prefix ID on each interface, only the first 56 bits change).

New GUA prefix of a subnet = first 56 bits of the new delegated prefix + the same subnet ID (2 hex digits). Example with a new delegated prefix `2001:db8:1234:ab00::/56`:

| Usage | Subnet ID | Current | New |
| --- | --- | --- | --- |
| Administration subnet | `0a` | `2a02:8434:f003:d10a::/64` | `2001:db8:1234:ab0a::/64` |

### Automatic (nothing to do)

| Where | Why |
| --- | --- |
| OPNsense interfaces and router advertisements | Interfaces track the WAN delegated prefix (DHCPv6-PD). |
| OPNsense *Dynamic IPv6 Host* aliases | The interface identifier is combined with the current prefix of the interface. |
| Cilium BGP sessions | Between ULA addresses. |
| NAS | Static ULA on the nodes subnet, SLAAC on its main interface. |

### Manual

#### 1. Repository: pod baseline

- [ ] **Pod baseline.** In `kubernetes/apps/kube-system/cilium/policies/baseline.yaml`, replace the delegated /56 in the `except` list of `::/0` (keep the Milkywan /48). Until then, the pods can reach the GUA of the LAN devices as `world`, past their firewall ([cluster](../cluster/README.md#network-policies)).
- [ ] **Deployment.** Commit and push, then:

  ```sh
  flux reconcile kustomization cilium-policies -n kube-system --with-source
  ```

#### 2. OPNsense: firewall

- [ ] **Administration rule.** *Administration subnets → nodes* and *→ LoadBalancer pools* ([firewall](bootstrap.md#3-firewall)), if they use the GUA of the administration subnet.
- [ ] **GUA networks.** Any rule or alias written with a GUA network instead of an interface network macro (`<interface> net`) or a *Dynamic IPv6 Host* alias. To find them, search for the old prefix in *System → Configuration → Backups* (download the XML).

#### 3. DNS

- [ ] **OpenTofu.** AAAA records with an ISP GUA address, if any: update them in `tofu/cloudflare`, then:

  ```sh
  just tofu plan cloudflare
  just tofu apply cloudflare
  ```

  The applications are not concerned: their names are CNAMEs to `gateway-external.kube-cluster01.shelltopia.net`, in the Milkywan /48.

- [ ] **Unbound.** Host overrides with an ISP GUA address, if any (the node names and internal services use ULA addresses).

#### 4. Elsewhere

- [ ] **Ansible.** `home` and the other Ansible-managed hosts, while they still exist: the production inventory is encrypted, check it for the old prefix:

  ```sh
  ansible-vault view <inventory file>
  ```

- [ ] **Allowlists.** Third-party allowlists filtering on your IPv6 addresses (if any).
- [ ] **Documentation.** List the remaining examples (in `docs/`) and update them for consistency:

  ```sh
  git grep 2a02:8434
  ```

### Final checks

- [ ] **From the LAN:** a host has an address of the new prefix and reaches the internet over IPv6.
- [ ] **Pods:** the baseline still blocks the LAN. From a pod, the NAS, OPNsense and the other LAN devices are unreachable, except by an exception by name.

### Reducing the work

- Use a single OPNsense *Network* alias for the ISP prefixes in every rule: one place to change instead of every rule.
- Prefer interface network macros and *Dynamic IPv6 Host* aliases to GUA networks in the rules.
