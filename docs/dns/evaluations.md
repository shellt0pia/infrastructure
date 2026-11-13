# DNS: evaluations and open points

What was decided against or accepted, and what is still pending. The resulting architecture is in [README.md](README.md).

## Rejected options

| Option | Why not |
| --- | --- |
| external-dns webhook for OPNsense/Unbound | k8s-gateway serves `shelltopia.org` from the routes of the `internal` Gateway, and Unbound forwards the zone to it: no write access to OPNsense from the cluster. |
| CoreDNS chart + a second external-dns instance (`coredns` provider) instead of k8s-gateway | The `coredns` provider writes to etcd, read by the `etcd` plugin of CoreDNS: one more stateful component, without quorum on 2 nodes (the etcd of Talos is out of the question). In-tree provider without maintainer. Same result on the LAN as k8s-gateway. |
| Copy of the public records in k8s-gateway (`file` plugin, `DNSEndpoint`) | Duplicates what OpenTofu manages, and k8s_gateway only answers `A`, `AAAA` and `TXT` (no MX nor CNAME). Replaced by the fallthrough to the public zone. |
| Delegated internal subzone (`*.int.shelltopia.org`), the rest resolved publicly | Every name changes, and the wildcard certificate `*.shelltopia.org` does not cover them. |
| Unbound as upstream of the fallthrough | It forwards `shelltopia.org` to k8s-gateway: the query would loop. The baseline network policy blocks the private networks anyway. |
| Records of the applications in OpenTofu | They follow the HTTPRoutes: external-dns publishes them, OpenTofu only keeps the zones, the infrastructure records and the names of `home`. |
| One GatewayClass for both Gateways | k8s-gateway selects the Gateways by class: a route attached to both must only resolve to the internal addresses on the LAN. |

## Accepted limits

| Topic | Notes |
| --- | --- |
| Zone lost on the LAN while the cluster is down | `shelltopia.org` no longer resolves (`SERVFAIL`). Everything in this zone is served by the cluster, except the names still on `home` (host overrides). |
| Public names visible in the zone | The CNAMEs of the public applications are listed in the Cloudflare zone. The application names stay out of the Certificate Transparency logs thanks to the [wildcard certificate](../ingress/README.md#certificate). |
| Pinned addresses of k8s-gateway | Unbound only accepts addresses as forward targets. Every LoadBalancer address is pinned anyway ([conventions](../conventions.md#loadbalancer-addresses)). |
| Receiver names by hand | `syslog.kubecluster-01.shelltopia.net` is an Unbound host override kept in sync with the pinned addresses by hand, until an external-dns webhook for OPNsense/Unbound is evaluated. |
| Fallthrough through the Cloudflare resolvers | The names of `shelltopia.org` without route (mail, SPF, cloud services) resolve on the LAN through 1.1.1.1 rather than through the recursion of Unbound. Cloudflare already hosts the zone: no new third party sees the names. |
| Public-only routes on the LAN | A route attached to the `external` Gateway only resolves on the LAN to its public CNAME: the WAN IPv4 (HAProxy, then port forwarding, from the LAN) or the IPv6 of the `external` Gateway. Attach the route to both Gateways to stay on the internal one. |

## Open points

| Topic | Notes |
| --- | --- |
| Milkywan WireGuard tunnel (planned) | With its stable IPv4, cloudflare-ddns is removed and the `A` record of `gateway-external.kubecluster-01.shelltopia.net` becomes static in OpenTofu. |
| Historical names of `home` | The CNAMEs of `shelltopia.org` to the Ansible hosts and the `ddns-updater` records are removed during the migration ([procedure](../ingress/runbook.md#migrating-a-name-from-home)). |
| DNSSEC validation on Unbound | If it is ever enabled, add `shelltopia.org` to its insecure domains (`domain-insecure`). |
| Token expirations | Cloudflare tokens (cert-manager, external-dns, cloudflare-ddns, OpenTofu), see [secrets](../secrets/runbook.md#tokens-to-renew). |
