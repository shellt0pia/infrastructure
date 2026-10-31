# DNS: evaluations and open points

What was decided against or accepted, and what is still pending. The resulting architecture is in [README.md](README.md).

## Rejected options

| Option | Why not |
| --- | --- |
| external-dns webhook for OPNsense/Unbound | k8s-gateway is authoritative for `shelltopia.org` from the routes of the `internal` Gateway, and Unbound forwards the zone to it. |
| Records of the applications in OpenTofu | They follow the HTTPRoutes: external-dns publishes them, OpenTofu only keeps the zones, the infrastructure records and the names of `home`. |
| One GatewayClass for both Gateways | k8s-gateway selects the Gateways by class: a route attached to both must only resolve to the internal addresses on the LAN. |

## Accepted limits

| Topic | Notes |
| --- | --- |
| Zone lost on the LAN while the cluster is down | `shelltopia.org` no longer resolves (`SERVFAIL`). Everything in this zone is served by the cluster, except the names still on `home` (host overrides). |
| Public names visible in the zone | The CNAMEs of the public applications are listed in the Cloudflare zone. The application names stay out of the Certificate Transparency logs thanks to the [wildcard certificate](../ingress/README.md#certificate). |
| Pinned addresses of k8s-gateway | An exception to the "everything dynamic" rule: Unbound only accepts addresses as forward targets. |

## Open points

| Topic | Notes |
| --- | --- |
| Milkywan WireGuard tunnel (planned) | With its stable IPv4, cloudflare-ddns is removed and the `A` record of `gateway-external.kube-cluster01.shelltopia.net` becomes static in OpenTofu. |
| Historical names of `home` | The CNAMEs of `shelltopia.org` to the Ansible hosts and the `ddns-updater` records are removed during the migration ([procedure](../ingress/runbook.md#migrating-a-name-from-home)). |
| DNSSEC validation on Unbound | If it is ever enabled, add `shelltopia.org` to its insecure domains (`domain-insecure`). |
| Token expirations | Cloudflare tokens (cert-manager, external-dns, cloudflare-ddns, OpenTofu), see [secrets](../secrets/runbook.md#tokens-to-renew). |
