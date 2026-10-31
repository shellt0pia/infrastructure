# DNS: first deployment

Deploying the DNS tools of the applications on a new cluster, and configuring OPNsense and Cloudflare for them. Architecture: [README.md](README.md). The Gateways come first ([ingress](../ingress/bootstrap.md)): external-dns waits for them, otherwise it reads the redirect route before its annotation and publishes a wildcard record.

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kube-cluster01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | Cloudflare token `cloudflare-external-dns` (*Zone → Zone → Read*, *Zone → DNS → Edit*, restricted to `shelltopia.org` and `shelltopia.net`), item of the `kubernetes` vault, field `credential`. | Cloudflare dashboard, then 1Password | Done |
| 1 | Cloudflare token `cloudflare-ddns` (same permissions, restricted to `shelltopia.net`), item of the `kubernetes` vault, field `credential`. | Cloudflare dashboard, then 1Password | Done |
| 1 | The Gateways, with the `internal` pool and the pinned addresses of k8s-gateway free. | [ingress/bootstrap.md](../ingress/bootstrap.md) | Done |
| 3 | OpenTofu: bucket of the states and its items. | [tofu/README.md](../../tofu/README.md#setup) | Done |

## 1. Deploy and check

`kubernetes/apps/network` deploys k8s-gateway, external-dns and cloudflare-ddns.

- [x] **Deployment.** Push, then:

  ```sh
  flux get ks -n network
  kubectl -n network get externalsecret
  ```

  Expected: `k8s-gateway`, `external-dns` and `cloudflare-ddns` are `Ready`. The ExternalSecrets `external-dns-cloudflare` and `cloudflare-ddns` are `SecretSynced`.

- [x] **k8s-gateway addresses:**

  ```sh
  kubectl -n network get svc k8s-gateway -o wide
  ```

  Expected: `192.168.19.53` and `fd38:4c4d:8f66:13::53`. Without address, another Service already holds one of them.

- [x] **Internal names:**

  ```sh
  dig +short app.shelltopia.org @192.168.19.53
  dig +short +tcp AAAA app.shelltopia.org @fd38:4c4d:8f66:13::53
  ```

  Expected: the addresses of the `internal` Gateway. A name without route: `NXDOMAIN`. Then the same queries through Unbound (its address instead of the k8s-gateway ones).

- [x] **external-dns, dry run.** On the first deployment, to see what it would do without changing anything, add `dry-run: true` to its `extraArgs`, then:

  ```sh
  kubectl -n network logs deploy/external-dns
  ```

  Expected: a `CREATE` of `gateway-external.kube-cluster01.shelltopia.net` `AAAA` (and its `aaaa-` TXT record). Never a `*.shelltopia.org` record. In dry-run, a planned change is logged again at every cycle: a change logged once only came from a transient state. Then remove `dry-run`.

- [x] **Public names:**

  ```sh
  dig +short CNAME app.shelltopia.org @1.1.1.1
  dig +short A gateway-external.kube-cluster01.shelltopia.net @1.1.1.1
  dig +short AAAA gateway-external.kube-cluster01.shelltopia.net @1.1.1.1
  ```

  Expected: the CNAME, the WAN IPv4 and the IPv6 of the `external` Gateway.

- [x] **cloudflare-ddns:**

  ```sh
  kubectl -n network logs deploy/cloudflare-ddns
  ```

  Expected: the detected IPv4 and the record update, no error.

## 2. OPNsense: Unbound

- [x] **Forward.** *Services → Unbound DNS → Query Forwarding*: domain `shelltopia.org`, servers `192.168.19.53` and `fd38:4c4d:8f66:13::53`, port 53.
- [x] **Host overrides.** Remove the host overrides of `shelltopia.org` for the names served by the cluster. Keep those of the names still served by `home` until they are migrated: the host overrides (`local-data`) win over the forward.
- [x] **Firewall.** The queries come from the firewall itself, no rule is needed. Optional, for the tests with `dig`: administration subnets → `192.168.19.53` and `fd38:4c4d:8f66:13::53`, TCP and UDP 53.
- **DNSSEC.** `shelltopia.org` is signed on Cloudflare, but Unbound does not validate (its upstream does), so the unsigned answers of k8s-gateway are accepted. If validation is ever enabled on Unbound, add `shelltopia.org` to its insecure domains (`domain-insecure`).

## 3. OpenTofu: the other records

Independent from the cluster, can wait. Needs the [setup of tofu/README.md](../../tofu/README.md#setup) first: bucket of the states, `infrastructure/tofu-state-encryption` and `infrastructure/backblaze-b2-tofu-state` items.

- [x] **Cloudflare stack.** Follow the [Cloudflare setup](../../tofu/README.md#cloudflare-setup) (zones, token and `infrastructure/cloudflare-tofu` item), then:

  ```sh
  just tofu init cloudflare
  just tofu apply cloudflare
  ```

  Then the DS records at the registrars, and:

  ```sh
  just tofu plan cloudflare
  ```

  Expected: the plan shows no change.

- [x] **Records managed from the cluster.** Never add them to the stack (they would be fought over): the CNAMEs of the applications in `shelltopia.org` and their `cname-*` TXT records (external-dns), the `A` (cloudflare-ddns), `AAAA` and `aaaa-*` TXT (external-dns) records of `gateway-external.kube-cluster01.shelltopia.net`. Their comment says which tool manages them. See the [rules](README.md#overview).
