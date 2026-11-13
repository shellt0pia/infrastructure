# Ingress: evaluations and open points

What was considered or rejected, and what is still pending. The resulting architecture is in [README.md](README.md).

## HSTS preload

Every response carries the `preload` token, which is harmless on its own. Submitting `shelltopia.org` to [hstspreload.org](https://hstspreload.org) would also require the apex to serve HTTPS with this header, and would force HTTPS on every subdomain in the browsers, permanently. Not planned.

## Rejected options

| Option | Why not |
| --- | --- |
| Gateway API of Cilium | Stays disabled. Envoy Gateway is more complete (client, backend and security policies, PROXY protocol, HTTP/3) and its proxies are separate from the CNI. |
| Plain port forwarding of 80/443 for IPv4 during the migration | `home` still serves names on the same ports: HAProxy routes on the SNI and the Host header. It goes away with `home` ([procedure](runbook.md#removing-haproxy)). |
| HTTP/3 behind HAProxy | HAProxy cannot forward QUIC: HTTP/3 is on the internal Gateway only. |
| Allow-list of the clients of the `internal` Gateway (`SecurityPolicy`, RFC 1918 and `fd00::/8`) | Removed on 2026-11-13. Its addresses are private already: it only protected a route attached to it by mistake while its name is public, a risk accepted. Its routes rely on the login of the application, or on a `SecurityPolicy` with `oidc` on the route when the application has none (Hubble UI). |

## Open points

| Topic | Notes |
| --- | --- |
| Port forwarding instead of HAProxy | Once `home` is migrated: [procedure](runbook.md#removing-haproxy). |
| `ecdhCurves` | The names are passed as is to Envoy (BoringSSL). After an Envoy upgrade, check that the listeners are not rejected (logs of `envoy-gateway`). |
| Milkywan WireGuard tunnel | Stable public IPv4 and IPv6 prefix, in place: the `external` pool, the OPNsense prefix list and HAProxy are on it ([network](../network/milkywan.md)). Left: DNS ([roadmap](../roadmap.md#to-check-or-watch)). |
| Per-route needs at migration | Basic authentication (`SecurityPolicy` on the route), Plex over HTTPS to its backend (or *Secure connections: Preferred*). |
