# Ingress: runbook

Day-to-day administration of the Gateways. Architecture: [README.md](README.md).

## Exposing an application

Internal only:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app
spec:
  parentRefs:
    - name: internal
      namespace: network
  hostnames:
    - app.shelltopia.org
  rules:
    - backendRefs:
        - name: app
          port: 80
```

The route must list its `hostnames`: the DNS records are created from them (see [DNS](../dns/README.md#overview)), a route without hostname gets none.

Public: label the namespace of the application with `shelltopia.net/gateway-external: "true"` (in its `namespace.yaml`), and attach the route to **both** Gateways. The LAN clients then stay on the internal Gateway (internal DNS, see [DNS](../dns/README.md#overview)) and get HTTP/3, the internet gets a CNAME to the external Gateway:

```yaml
  parentRefs:
    - name: internal
      namespace: network
    - name: external
      namespace: network
```

Without `sectionName`, the route attaches to every HTTPS listener of the external Gateway (`https` and `https-proxy`), so it is reachable both directly over IPv6 and through HAProxy over IPv4.

Check the route:

```sh
kubectl get httproute app -o yaml
```

Expected: each parent has `Accepted: True` and `ResolvedRefs: True`. On the external Gateway, the `http` and `http-proxy` listeners refuse the route (`NotAllowedByListeners`) but `Accepted` stays `True` thanks to the HTTPS listeners.

Per-route settings (later, at migration time): basic authentication with a `SecurityPolicy` targeting the `HTTPRoute`, specific timeouts in the route rules, TLS to an HTTPS backend with a `Backend` resource or a `BackendTLSPolicy`.

## Testing a change with the staging issuer

The `Certificate` `shelltopia-org` is issued by `letsencrypt-production`. To test a change of the issuers or of the Cloudflare token without touching the rate limits of production:

1. **Switch to staging.** Set `issuerRef.name` to `letsencrypt-staging` in `kubernetes/apps/network/gateways/app/certificate.yaml`, commit and push. cert-manager issues the new certificate right away.

2. **Check the served certificate:**

   ```sh
   curl -kv https://app.shelltopia.org 2>&1 | grep -i issuer
   ```

   Expected: the issuer contains `(STAGING)`.

3. **Switch back to production**, the same way.

## Migrating a name from `home`

1. **Deploy the application** with its route (`hostnames`, attached to the right Gateway(s)).
2. **Public name.** Remove its current records from the Cloudflare dashboard. The historical names are not managed by OpenTofu; if one is, remove it from `tofu/cloudflare`, then:

   ```sh
   just tofu apply cloudflare
   ```

   external-dns creates the CNAME within a minute. Update [HAProxy](bootstrap.md#haproxy-ipv4-during-the-migration): the name goes to the `external` Gateway instead of `home`.

3. **Internal name.** Remove its Unbound host override, the forward to k8s-gateway takes over.

The records are explained in [dns](../dns/README.md).

## Gateway address changed

The address of a Gateway comes from the pool: it stays the same as long as its Service exists. If the Gateway is recreated:

1. **Check its address:**

   ```sh
   kubectl -n network get gateway external
   ```

2. **Update the real servers** of HAProxy ([HAProxy](bootstrap.md#haproxy-ipv4-during-the-migration)).

## Removing HAProxy

Once `home` no longer serves anything:

- [ ] **Port forwarding.** WAN IPv4 TCP 80 and 443 → `external` Gateway IPv4, same ports (direct listeners, no PROXY protocol).
- [ ] **Proxy listeners.** Remove the `http-proxy` and `https-proxy` listeners (`gateway-external.yaml`), the `external-proxy-protocol` `ClientTrafficPolicy` and the matching `parentRefs` of the redirect route.
