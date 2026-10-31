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

## A certificate is not issued or renewed

The wildcard `Certificate` `shelltopia-org` lives in `network`, and cert-manager renews it by itself. If the issuance fails, the Gateways keep serving the previous certificate until it expires.

1. **Follow the chain**, from the Certificate to the DNS-01 challenge (these objects are in the namespace of the Certificate):

   ```sh
   kubectl -n network get certificate shelltopia-org
   kubectl -n network get certificaterequest,order,challenge
   kubectl -n network describe challenge
   ```

   Expected, when healthy: the Certificate `Ready`, no pending Order or Challenge. Otherwise, the `describe` of the failing object gives the reason.

2. **Read the controller logs:**

   ```sh
   kubectl -n cert-manager logs deploy/cert-manager
   ```

3. **Look for the cause:**

   - **The Cloudflare token** (authorization error, `403`): expired or revoked. Check the ExternalSecret, then [replace the token](../secrets/runbook.md#replacing-a-token-synced-to-the-cluster) (item `cloudflare-cert-manager`):

     ```sh
     kubectl -n cert-manager get externalsecret cloudflare-api-token
     kubectl get clusterissuers
     ```

     Expected: `SecretSynced`, both issuers `Ready`.

   - **The propagation check never succeeds** (the challenge stays `pending`, `propagation check failed`): the nodes must reach the public resolvers set in `dns01RecursiveNameservers` ([firewall](../network/bootstrap.md#3-firewall)), and `dns01RecursiveNameserversOnly` must still be `true` in the cert-manager values.

   - **Let's Encrypt rate limit.** Test with the [staging issuer](#testing-a-change-with-the-staging-issuer) first: a rebuild repeated several times in a week may hit the limit on duplicate certificates.

4. **Retry**, once the cause is fixed. Either wait for cert-manager, or delete the failed `CertificateRequest` so that it creates a new one:

   ```sh
   kubectl -n network delete certificaterequest <name>
   kubectl -n network get certificate shelltopia-org -w
   ```

   Expected: the Certificate becomes `Ready`.

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
