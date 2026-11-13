# DNS: runbook

Day-to-day operations on the DNS records. Architecture: [README.md](README.md).

## Where to create a record

| Record | Owner | How |
| --- | --- | --- |
| Name of an application served by the cluster | k8s-gateway (internal), external-dns (public) | Nothing by hand: list its `hostnames` in the HTTPRoute and attach it to the right Gateway(s) ([ingress](../ingress/runbook.md#exposing-an-application)). |
| Other records of `shelltopia.org` and `shelltopia.net` in Cloudflare (mail, CAA, PikaPods, SSL settings) | OpenTofu | Edit `tofu/cloudflare`, then see below. |
| Names of the nodes, the cluster endpoint, the internal services (NAS, NTP, UPS) | Unbound on OPNsense | Host overrides ([network](../network/README.md#names)). |
| Names of the receivers of the cluster (`syslog.kubecluster-01.shelltopia.net`) | Unbound on OPNsense | Host overrides `A` and `AAAA`, to the [pinned addresses](../reference.md#pinned-loadbalancer-addresses) of their Service: update both together. |
| `A` and `AAAA` of `shelltopia.net` (hosts, firewall, WireGuard endpoints) | ddns-updater, or by hand | Not managed from the cluster. |

Never add to `tofu/cloudflare` a record owned by external-dns or cloudflare-ddns (the CNAMEs of the applications, the `cname-*` and `aaaa-*` TXT records, the `A` and `AAAA` of `gateway-external.kubecluster-01.shelltopia.net`): the tools would fight over it ([rules](README.md#overview)).

## Changing a record managed by OpenTofu

- [ ] **Edit** the record in `tofu/cloudflare`, then check what changes:

  ```sh
  just tofu plan cloudflare
  ```

  Expected: only the record you changed.

- [ ] **Apply:**

  ```sh
  just tofu apply cloudflare
  just tofu plan cloudflare
  ```

  Expected: the second plan shows no change.

## A name does not resolve

Start from where the client is: the LAN gets the internal Gateway through Unbound and k8s-gateway, the internet gets the CNAME in Cloudflare.

1. **Compare the two sides:**

   ```sh
   dig +short app.shelltopia.org
   dig +short app.shelltopia.org @1.1.1.1
   ```

   Expected: the addresses of the `internal` Gateway for the first one, and a CNAME to `gateway-external.kubecluster-01.shelltopia.net` for the second one (public names only). Continue with the side that fails.

2. **Internal name.** Ask k8s-gateway directly, bypassing Unbound:

   ```sh
   dig +short app.shelltopia.org @192.168.19.53
   dig +short +tcp AAAA app.shelltopia.org @fd38:4c4d:8f66:13::53
   ```

   - **It answers, Unbound does not.** The forward of `shelltopia.org` is missing or points to other addresses ([Unbound](bootstrap.md#2-opnsense-unbound)), or a host override of the name is left in Unbound: the host overrides win over the forward.
   - **`NXDOMAIN`, or the public answer (CNAME to `gateway-external...`).** No route of the `internal` Gateway matches: k8s-gateway passes the name to the Cloudflare resolvers. It ignores a route without `hostnames`, and a route whose parent Gateway is not the `internal` one. Check the route:

     ```sh
     kubectl get httproute -A
     kubectl get httproute app -o yaml
     ```

   - **`SERVFAIL` for a name without route** (MX, SPF, cloud services) while the routes resolve: the forward to the Cloudflare resolvers fails. Look for errors in `kubectl -n network logs deploy/k8s-gateway`, and for dropped flows to `world` on port 853 in Hubble.
   - **No answer at all.** Check the Service and the pods; without an address, another Service holds one of the pinned addresses:

     ```sh
     kubectl -n network get svc k8s-gateway -o wide
     kubectl -n network get pods | grep k8s-gateway
     ```

   When the cluster is down, `shelltopia.org` no longer resolves on the LAN (`SERVFAIL`): see [k8s-gateway](README.md#internal-k8s-gateway).

3. **Public name.** Read what external-dns does:

   ```sh
   kubectl -n network logs deploy/external-dns
   ```

   - **Nothing is created for the name.** The route is not attached to the `external` Gateway (or not accepted by it, [check the route](../ingress/runbook.md#exposing-an-application)). Otherwise, a record already exists on the name: an existing `CNAME` or `AAAA` makes external-dns skip it silently, only visible with `--log-level=debug` in its `extraArgs`. Remove the record in the Cloudflare dashboard, external-dns creates the CNAME within a minute.
   - **An error every minute.** Any other record (`A`, `TXT`...) on the name makes Cloudflare reject the CNAME: remove it.
   - **A wildcard `*.shelltopia.org` planned.** A route without `hostnames` or a redirect route without `external-dns.kubernetes.io/gateway-hostname-source: defined-hosts-only`. Do not let it through: check with `dry-run` first (below).

4. **The entry name.** The CNAMEs point to it, it needs its `A` and its `AAAA`:

   ```sh
   dig +short A gateway-external.kubecluster-01.shelltopia.net @1.1.1.1
   dig +short AAAA gateway-external.kubecluster-01.shelltopia.net @1.1.1.1
   kubectl -n network logs deploy/cloudflare-ddns
   ```

   Expected: the WAN IPv4 (cloudflare-ddns, every 5 minutes) and the IPv6 of the `external` Gateway (external-dns).

## Checking what external-dns would do

To see the changes without applying them, for instance before attaching a first route to the external Gateway:

- [ ] **Dry run.** Add `dry-run: true` to `extraArgs` in `kubernetes/apps/network/external-dns/app/helmrelease.yaml`, commit and push, then:

  ```sh
  kubectl -n network logs deploy/external-dns
  ```

  Expected: the `CREATE` and `DELETE` it would do, logged again at every cycle: a change logged once only came from a transient state.

- [ ] **Back to normal.** Remove `dry-run`, commit and push.

## Changing the addresses of k8s-gateway

They are pinned, as every LoadBalancer address ([conventions](../conventions.md#loadbalancer-addresses)), and Unbound only accepts addresses as forward targets.

- [ ] **Reference.** Allocate the new addresses in the [reference](../reference.md#pinned-loadbalancer-addresses).

- [ ] **Service.** Change the `lbipam.cilium.io/ips` annotation in `kubernetes/apps/network/k8s-gateway/app/helmrelease.yaml`, commit and push. The new addresses must belong to the `internal` pool and be free:

  ```sh
  kubectl -n network get svc k8s-gateway -o wide
  ```

- [ ] **Unbound.** *Services → Unbound DNS → Query Forwarding*: the servers of `shelltopia.org`.
