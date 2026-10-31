# Ingress: first deployment

Deploying the Gateways on a new cluster, the checks to run, and the OPNsense rules in front of them. Architecture: [README.md](README.md). The DNS records of the applications have their own [first deployment](../dns/bootstrap.md).

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kube-cluster01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | Cluster: Cilium with the `internal` and `external` LB pools and the BGP sessions, External Secrets with the `onepassword` ClusterSecretStore. | [first-bootstrap.md](../first-bootstrap.md) | Done |
| 1 | cert-manager and the `letsencrypt-staging` and `letsencrypt-production` ClusterIssuers, with the Cloudflare token: item `cloudflare-cert-manager` of the `kubernetes` vault (field `credential`, token with *Zone → DNS → Edit* and *Zone → Zone → Read*). | `kubectl get clusterissuers`: both `Ready` | Done |
| 2 | Firewall and HAProxy on OPNsense. | [Below](#2-opnsense) | Done |

## 1. Deploy and check

`kubernetes/apps/envoy-gateway-system` deploys the controller, `kubernetes/apps/network/gateways` the Gateways and the certificate.

- [x] **Deployment.** Push, then:

  ```sh
  flux get ks -A
  flux get hr -n envoy-gateway-system
  ```

  Expected: the Kustomizations `envoy-gateway` and `gateways` and the HelmRelease `envoy-gateway` are `Ready`.

- [x] **GatewayClasses and Gateways:**

  ```sh
  kubectl get gatewayclass
  kubectl -n network get gateway
  ```

  Expected: `internal` and `external` are `ACCEPTED`. Both Gateways are `PROGRAMMED`, with an IPv4 address from their pool (the IPv6 one is in `status.addresses`).

- [x] **Certificate:**

  ```sh
  kubectl -n network get certificate
  ```

  Expected: `shelltopia-org` is `Ready`.

- [x] **Policies:**

  ```sh
  kubectl -n network get clienttrafficpolicy,backendtrafficpolicy,securitypolicy -o wide
  kubectl -n network describe clienttrafficpolicy,backendtrafficpolicy,securitypolicy
  ```

  Expected: `Accepted`, and no conflict between `external` and `external-proxy-protocol` (the section policy overrides the Gateway one).

- [x] **Services:**

  ```sh
  kubectl -n envoy-gateway-system get svc -o wide
  ```

  Expected: one LoadBalancer Service per Gateway, two addresses each, with UDP 443 on the internal one.

- [x] **Controller logs:**

  ```sh
  kubectl -n envoy-gateway-system logs deploy/envoy-gateway | grep -i -E 'error|nack'
  ```

  Expected: no rejected configuration. An unknown curve name in `ecdhCurves` would show here (and in the logs of the Envoy pods) while the policy stays `Accepted`: fall back to `[X25519, P-256]`.

The first certificate was issued by `letsencrypt-staging` then switched to production, [how](runbook.md#testing-a-change-with-the-staging-issuer).

## 2. OPNsense

### Firewall

- [x] **Clients.** Client subnets (LAN, VPN) → `internal` pool (`192.168.19.0/25`, `fd38:4c4d:8f66:13::/64`): TCP 80 and 443, UDP 443 (HTTP/3).
- [x] **Internet.** WAN → `external` pool IPv6 (`2a02:8434:f003:d113::/64`): **TCP 80 and 443 only**. The Service also exposes 8080 and 8443, which must never be reachable from the internet: Envoy trusts any PROXY protocol header on them, a client could spoof its address.
- [x] **HAProxy.** No rule is needed for HAProxy → `external` pool IPv4 (8080, 8443): the traffic comes from the firewall itself.
- [x] **Direct ports.** Do not open 8080 and 8443 of the `external` pool to the LAN either, for the same reason. The tests of these ports run from a pod.

The `external` pool is in the GUA prefix delegated by the ISP: when it changes, the rules follow ([IPv6 prefix change](../ipv6-prefix-change.md)).

### HAProxy (IPv4, during the migration)

There is no IPv4 port forwarding on 80/443: HAProxy listens on the WAN address with a `http` frontend (port 80, routing on the Host header) and a `https` frontend (port 443, TCP mode, routing on the SNI without terminating TLS). Each name has a rule: the names still served by `home` go to it, the names migrated to the cluster go to the `external` Gateway, with the PROXY protocol so that Envoy sees the client address. A name without rule gets its connection closed (no default backend):

- [x] **Real servers.** Look up the address of the `external` Gateway:

  ```sh
  kubectl -n network get gateway external
  ```

  Then create the real servers with PROXY protocol v2 (`send-proxy-v2`). Two real servers: port `8080` for HTTP, port `8443` for HTTPS. Set the **port of the real server** itself, not only the health check port: a server without port receives the connections on the port the client used (80 or 443, the direct listeners, which do not expect the PROXY header), while the health checks on 8080/8443 keep it UP. With an FQDN, set the resolution preference to IPv4 (`resolve-prefer ipv4`, HAProxy prefers IPv6 by default): HAProxy only receives IPv4 clients.
- [x] **Backend pools.** One for HTTP (8080), one for HTTPS (8443, TCP mode).
- [x] **Conditions and rules:**
  - frontend `https`: SNI matches a migrated name (`req.ssl_sni`) → HTTPS backend;
  - frontend `http`: Host matches a migrated name → HTTP backend.
- [x] **Names of `home`.** The names still served by `home` keep their own rules and backends.

The address of the Gateway comes from the pool: it stays the same as long as its Service exists. If the Gateway is recreated, or after a change of its `GatewayClass` (the split of the `envoy` class into `internal` and `external`), check it again and update the real servers.

### Unbound

See the [DNS first deployment](../dns/bootstrap.md#2-opnsense-unbound).
