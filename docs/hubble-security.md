# Hubble UI and enforcement of the network policies

Temporary document: the plan of the [Security](roadmap.md#security) section of the roadmap. It is deleted at the end (last step), once its decisions are in the documents of their topics ([cluster](cluster/README.md#network-policies), [ingress](ingress/README.md)). *Not tested yet*: adjust the manifests and the checks while running them.

What changes:

| Before | After |
| --- | --- |
| The `internal` Gateway answers the private networks only (`SecurityPolicy` `internal`, allow-list of RFC 1918 and `fd00::/8`) | No filter on the clients: its addresses are private (`internal` pool), only the LAN and the VPN reach them. A route attached to it by mistake while its name is public is a risk accepted |
| Hubble: Relay and the `hubble` CLI, through a port-forward | Hubble UI too, as `hubble.shelltopia.org` on the `internal` Gateway, behind a login on the Pocket ID done by Envoy (`SecurityPolicy` with `oidc` on its route), for the group `kubernetes_admins` |
| Network policies in audit mode | Enforced (`policyAuditMode: false`) |

Hubble UI has no login of its own and no notion of user: its backend reads the flows from Relay and the API server with its own ServiceAccount (read-only `ClusterRole` of the Cilium chart). The OIDC authentication of the API server ([Cluster tools](roadmap.md#cluster-tools)) changes nothing for it, the login is done by Envoy in front of it. Whoever passes the login sees every flow of the cluster: the access is restricted to a group.

Rules:

- One commit per step, each with the documents it changes ([AGENTS.md](../AGENTS.md#do-not)): the **Docs** line of each step.
- Step 1 is independent of the others and can be pushed first.

## Decisions

Answered on 2026-11-13. To move to the documents of their topics with the steps below.

| Topic | Decision |
| --- | --- |
| Name | `hubble.shelltopia.org` ([conventions](conventions.md#routes-and-names)). |
| Manifests | `kubernetes/apps/kube-system/cilium/hubble-ui/`: the route, the `SecurityPolicy` and the `ExternalSecret`, a third Kustomization `cilium-hubble-ui` in `cilium/ks.yaml`, as `cilium-networking` and `cilium-policies`. Not in `cilium/app`: the bootstrap installs Cilium before Envoy Gateway and External Secrets, whose CRDs they need. Hubble UI itself comes from the release of Cilium. |
| Group | `kubernetes_admins`, the group of the Kubernetes administrators, shared with the [OIDC login of Kubernetes](roadmap.md#cluster-tools) and its UIs. Checked by the Pocket ID only (allowed groups of the client): one place, nothing to keep in sync. No check of the `groups` claim by Envoy (`jwt` provider and `authorization` rules). |
| Tokens | Refreshed by Envoy (`refreshToken: true`, the default): the UI keeps its stream when the ID token expires. Unlike Grafana (`use_refresh_token` off), an outage of the Pocket ID ends nothing more: without it, a refresh fails as a new login does. |
| Client | Confidential, its id and its secret in the item `pocket-id-hubble` (`kubernetes` vault, [naming](secrets/README.md#naming-of-the-items)), read through `clientIDRef` and `clientSecret`, as Grafana. |
| `externalTrafficPolicy: Local` of the `internal` Gateway | Kept, its comment updated: only the allow-list of step 1 needed it, but it still avoids a hop between the nodes and keeps the client address in the logs of Envoy. |
| Next UIs without a login of their own | A `SecurityPolicy` with `oidc` on their route: a convention, written at step 4. |
| Resources of Hubble UI | Requests and a memory limit on both containers, *to resize from the metrics* as Grafana, before the convention of [Cluster tools](roadmap.md#cluster-tools). |
| Audited flows | Read: the only `AUDIT` flows come with a new tool or manifest, until its exceptions are written. The other drops are not verdicts of the policies (step 3). |

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 2 | The group `kubernetes_admins` in the Pocket ID, with its members. | Pocket ID | Done |
| 2 | A confidential OIDC client *Hubble UI*: callback `https://hubble.shelltopia.org/oauth2/callback`, logout callback `https://hubble.shelltopia.org/` (to check: Envoy may send no `post_logout_redirect_uri`), allowed groups: `kubernetes_admins`. PKCE only if Envoy sends a `code_challenge` (to check in the first redirect to the Pocket ID), off otherwise. | Pocket ID | Done |
| 2 | Item `pocket-id-hubble` (`kubernetes` vault): `username` is the client id, `credential` the secret. | 1Password | Done |
| 2 | The HMAC secret of the OIDC filter, created by the certgen Job of the Envoy Gateway chart: `kubectl -n envoy-gateway-system get secret envoy-oidc-hmac`. | Check | OK |
| 3 | The audited flows read, each one allowed or explained. | [cluster](cluster/bootstrap.md#network-policies) | Done |

## 1. Remove the client filter of the `internal` Gateway

- [x] **Files.** Delete `kubernetes/apps/network/gateways/app/securitypolicy.yaml` and its line in `kustomization.yaml`. The comments that point to it: `envoyproxy-internal.yaml` (`externalTrafficPolicy: Local`, [decisions](#decisions)) and `kubernetes/apps/envoy-gateway-system/envoy-gateway/app/ciliumnetworkpolicy.yaml` (*the internal one filters its clients itself*). Rendered locally:

  ```sh
  kubectl kustomize kubernetes/apps/network/gateways/app | grep -c 'kind: SecurityPolicy'
  ```

  Expected: `0`. Done.

- [ ] **Check**, once Flux has reconciled:

  ```sh
  kubectl -n network get securitypolicy
  curl -sI https://grafana.shelltopia.org
  ```

  Expected: no `SecurityPolicy` left in `network`. Grafana still answers from the LAN (`302` to its login).

- [x] **Docs:** [ingress](ingress/README.md#overview) (the row of the `internal` Gateway, and the decision with the risk accepted), [ingress evaluations](ingress/evaluations.md#rejected-options) (the allow-list, removed). The check of the policies in the [ingress bootstrap](ingress/bootstrap.md#1-deploy-and-check) stays as it was run.

## 2. Hubble UI behind the Pocket ID

The flows it needs are already allowed by the baseline ([cluster](cluster/README.md#network-policies)): the Envoy proxies to any backend, Hubble UI to Relay (same namespace) and to the API server, the Envoy proxies and the Envoy Gateway controller to `id.shelltopia.org` (the internet). Nothing to add, checked below.

- [x] **Release of Cilium.** `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`: `hubble.ui.enabled: true`, `rollOutPods: true`, one replica (chart default: nothing depends on it), the resources of `backend` and `frontend`. The security context of the chart already meets `restricted` (UID 1001, `RuntimeDefault`, no capability), though `kube-system` is exempt. The comment *No UI for now* updated. The bootstrap helmfile reads these values: Hubble UI is also installed at the bootstrap, without its route until Flux runs.
- [x] **Route and login.** `kubernetes/apps/kube-system/cilium/hubble-ui/`:
  - `externalsecret.yaml`: Secret `hubble-ui-oidc`, keys `client-id` and `client-secret` (the keys Envoy Gateway reads) from `pocket-id-hubble/username` and `/credential`, `refreshInterval: 1h`. Envoy Gateway watches the Secret: no Reloader.
  - `httproute.yaml`: `hubble.shelltopia.org`, parent `internal` in `network`, backend the Service `hubble-ui` port 80. No `sectionName`, as the route of Grafana: the `http` listener only accepts the routes of `network`.
  - `securitypolicy.yaml`: on the route, `oidc` with the issuer `https://id.shelltopia.org` (endpoints discovered), `clientIDRef` and `clientSecret` on the Secret above, the redirect `https://hubble.shelltopia.org/oauth2/callback`, `/logout`, the scopes `openid profile email groups`, `refreshToken: true`.
  - `ks.yaml` of `cilium`: the Kustomization `cilium-hubble-ui`, `targetNamespace: kube-system`, `dependsOn` `cilium`, `gateways` (`network`) and `external-secrets-stores` (`external-secrets`), and a comment saying why it is separate.

  Rendered locally, then against the schemas (network access):

  ```sh
  flux build kustomization cilium-hubble-ui --path kubernetes/apps/kube-system/cilium/hubble-ui \
    --kustomization-file kubernetes/apps/kube-system/cilium/ks.yaml --dry-run
  kubectl kustomize kubernetes/apps/kube-system/cilium/hubble-ui > .scratch/hubble-ui.yaml
  kubeconform -strict -summary -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    .scratch/hubble-ui.yaml
  ```

  Expected: valid, the `HTTPRoute`, the `SecurityPolicy` and the `ExternalSecret` in `kube-system`. And the chart rendered with the values (`helm template`, [AGENTS.md](../AGENTS.md#checking-a-change)): the Deployment and the Service `hubble-ui`. Done: the 7 resources valid (with `cilium/ks.yaml`); the Service `hubble-ui` on port 80 to 8081, the resources on both containers, a read-only `ClusterRole`, no Kubernetes `NetworkPolicy` from the chart.

- [ ] **Deployment**, once Flux has reconciled:

  ```sh
  flux -n kube-system get ks cilium cilium-hubble-ui
  kubectl -n kube-system get pods -l k8s-app=hubble-ui
  kubectl -n kube-system get externalsecret,httproute,securitypolicy
  kubectl -n kube-system describe securitypolicy hubble-ui
  kubectl -n envoy-gateway-system logs deploy/envoy-gateway | grep -i -E 'error|oidc'
  ```

  Expected: both Kustomizations `Ready`, the pod `Running` with its two containers, `SecretSynced`, the route and the policy `Accepted`, no error about the OIDC provider (discovery of the endpoints).

- [ ] **Name.** From the LAN, then from a public resolver:

  ```sh
  dig +short hubble.shelltopia.org
  dig +short hubble.shelltopia.org @1.1.1.1
  ```

  Expected: the addresses of the `internal` Gateway from the LAN (k8s-gateway reads the route), nothing in public.

- [ ] **Login.**

  ```sh
  curl -sI https://hubble.shelltopia.org
  ```

  Expected: `302` to `https://id.shelltopia.org/authorize`, with `code_challenge` or not (PKCE, prerequisites). In a browser: a member of `kubernetes_admins` lands on Hubble UI, picks a namespace and sees its flows; a user outside of it is refused by the Pocket ID. `/logout` clears the cookies, the next visit goes through the Pocket ID again.

- [ ] **Session**, an hour later (lifetime of the ID token, to check in the Pocket ID): the open page still receives flows (refreshed tokens).
- [ ] **Flows.** None of the flows of Hubble UI is audited:

  ```sh
  hubble observe -P --verdict AUDIT --namespace kube-system --last 1000 | grep -E 'hubble-ui|envoy'
  hubble observe -P --verdict AUDIT --namespace envoy-gateway-system --last 1000
  ```

  Expected: nothing.

- [ ] **Docs:** written with the files: [cluster](cluster/README.md#network-policies) (Hubble UI next to Relay, its login, the status), [cluster bootstrap](cluster/bootstrap.md#network-policies) (the check of Hubble UI, to tick once deployed), [cluster runbook](cluster/runbook.md#network-policies) (*Find the drop*), [reference](reference.md#1password-items) (the item, the uses of the Pocket ID), [roadmap](roadmap.md#cluster-tools) (the client of Hubble UI next to that of Grafana). Left once deployed: the status in the cluster README and the roadmap.

## 3. Enforce the network policies

The steps are those of the [cluster bootstrap](cluster/bootstrap.md#network-policies), not repeated here.

- [x] **Audited flows**, the checkbox of the cluster bootstrap. Done: the `AUDIT` flows only come with a new tool or manifest, until its exceptions are written. Three other drop reasons show up, without a verdict of the policies: the datapath of Cilium already drops them in audit mode, so the enforcement changes nothing for them. They are [open points](cluster/evaluations.md#open-points), they do not wait for the enforcement:
  - `INVALID_SOURCE_IP`, ICMPv6, from almost every namespace, sporadic: already known.
  - `UNKNOWN_L3_TARGET_ADDRESS`, at the deployment of new tools.
  - `FORBIDDEN_ICMPV6_MESSAGE`, from `kube-apiserver`.
- [ ] **Enforce**, the checkbox of the cluster bootstrap: `policyAuditMode: false`, then its checks. Look in Hubble UI as well as with the CLI. The alert of the denied flows switches from `action="audit"` to `action="dropped"` ([alerting](observability/README.md#alerting)): check that the rule follows.
- [ ] **Docs:** [cluster](cluster/README.md#status) (status of the network policies), [roadmap](roadmap.md#security).

## 4. Conventions and clean-up

- [ ] **Convention:** a UI without a login of its own gets a `SecurityPolicy` with `oidc` on its route, its own client in the Pocket ID with the allowed groups, in [conventions](conventions.md#routes-and-names) and the [ingress runbook](ingress/runbook.md#exposing-an-application). The `SecurityPolicy` of a route replaces the one of its Gateway: none is left on the Gateways after step 1, keep it so or merge them.
- [ ] **Roadmap:** the Security section removed or emptied, [roadmap](roadmap.md#security).
- [ ] **Delete** this document.
