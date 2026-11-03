# Conventions

How the repository is organised and the habits that the manifests, the Talos configuration and the documentation follow, so that a new application or setting looks like the others. The topics explain why each part exists, this page only collects the rules. An example of every pattern is the `kubernetes/apps/cert-manager` and `kubernetes/apps/network` folders.

## Layout

| Path | Content |
| --- | --- |
| `talos/` | The machine configs of the nodes, [render layers](../talos/README.md#render-layers) |
| `bootstrap/` | `just bootstrap cluster`: the stages up to Flux, [cluster](cluster/README.md#overview) |
| `kubernetes/apps/` | Everything Flux deploys, one folder per namespace |
| `kubernetes/components/` | Kustomize components shared by the applications, such as `volsync`, `network-policies` and `flux-alerts` |
| `kubernetes/mod.just` | The `just kube` recipes of the workstation |
| `tofu/` | OpenTofu stacks: `cloudflare` and `backblaze`, [tofu/README.md](../tofu/README.md) |
| `docs/` | This documentation, [format](README.md#format) |

Every `just` module (`talos`, `bootstrap`, `tofu`, `kube`) lists its recipes with `just <module>`, each recipe has a `[doc]`.

## Flux applications

Flux follows `kubernetes/apps` (`sync.path` of the `flux-instance` HelmRelease). Each namespace is a folder:

```text
kubernetes/apps/<namespace>/
├── kustomization.yaml        # namespace.yaml, the ks.yaml of every application, the network-policies and flux-alerts components
├── namespace.yaml
└── <app>/
    ├── ks.yaml               # the Flux Kustomization(s) of the application
    └── app/                  # what it deploys
        ├── kustomization.yaml
        ├── ocirepository.yaml
        ├── helmrelease.yaml
        ├── externalsecret.yaml
        └── ciliumnetworkpolicy.yaml
```

`kustomization.yaml` of the namespace sets `namespace:`, and each `ks.yaml` sets `targetNamespace`: the manifests of `app/` never repeat it.

### Flux Kustomizations

- `interval: 1h`, `prune: true`, `sourceRef` to `flux-system`, `wait: true`: a Kustomization is `Ready` once what it deploys is. No `timeout`: the wait lasts up to the `interval`, and a new revision cancels it ([cluster](cluster/README.md#decisions)).
- `dependsOn` for what the manifests need before they can be applied: the CRDs of another release, and the `ClusterSecretStore` (`external-secrets-stores` in `external-secrets`) for an `ExternalSecret`.
- A **separate Kustomization** when the manifests need the CRDs or the webhook installed by the release of the same application: `cert-manager` and `cert-manager-issuers`, `envoy-gateway` and `gateways`. The comment of the `ks.yaml` says why.
- Variables: `spec.postBuild.substitute`, no `$` in a manifest of a Kustomization that substitutes (it applies to every one of them, a literal `${...}` is written `$${...}`).
- Components: `spec.components`, with a path relative to `spec.path` ([backups](backups/runbook.md#backing-up-an-application)).

### Charts

- The chart comes from an `OCIRepository` of the application (`chartRef` in the `HelmRelease`), with the version pinned in it: Renovate updates it. A chart that only exists in a Helm repository uses a `HelmRepository`, as external-dns.
- `install.remediation.retries: -1`, `upgrade.cleanupOnFail: true` and `upgrade.remediation.retries: 3`.
- The bootstrap helmfile reads the chart, the version and the values from here: `kubernetes/apps` stays the only source ([cluster](cluster/README.md#overview)).
- The values explain in a comment what is not obvious (why a setting is set, which one to keep in sync with another file).

### Namespaces

- `kustomize.toolkit.fluxcd.io/prune: disabled` on every namespace created by the repository: a refactoring that drops a Kustomization must never delete a namespace and its volumes.
- `kube-system` is created by Kubernetes and not managed. It is exempt from Pod Security ([cluster](cluster/README.md#pod-security)).
- An application goes in its own namespace, or in one shared with the applications that need the same Pod Security level; never in `default`.
- The `kustomization.yaml` of every namespace, `kube-system` included, has `components: [../../components/network-policies, ../../components/flux-alerts]`: the pods of the namespace reach each other ([network policies](#network-policies)), and the failed reconciliations of its Flux objects reach the Alertmanager ([observability](observability/README.md#alerting): a Flux `Alert` only sees its own namespace).
- A namespace is `restricted` by default ([cluster](cluster/README.md#pod-security)), without Pod Security labels. If its pods cannot run so, it gets the lowest level that works (`baseline` before `privileged`): `pod-security.kubernetes.io/enforce`, `audit` and `warn` set to it, without `-version` (`latest`), and a comment naming the pods and the reason (`piraeus-datastore` and `debug`: privileged).
- A namespace whose applications are exposed on the internet carries `shelltopia.net/gateway-external: "true"` ([ingress](ingress/runbook.md#exposing-an-application)).

### Network policies

Every pod is in default deny ([cluster](cluster/README.md#network-policies)). Without anything more, an application reaches the cluster and the internet, and receives traffic from its namespace, its kubelet, the API server and the Gateways (its routes).

- Anything else it needs is a `CiliumNetworkPolicy` in `ciliumnetworkpolicy.yaml`, next to the application (in `app/`), with a comment that says which flow it allows and why.
- An egress from a pod to the internal network (NAS, OPNsense, a LAN or VLAN device) is filtered by name, never by address or subnet: a `toFQDNs` rule (`matchName`, or `matchPattern`) on the application that needs it, next to a DNS rule that lets Cilium learn the addresses behind the name (the example below). The names are those of the internal DNS, so every device that a pod reaches has a record. `toCIDR` only for a peer that has no name, with a comment saying why. The addresses stay out of the manifests, as everywhere else in the repository ([network](network/README.md#principles)).
- Select the peers, not the ports: `fromEntities` (`world`, `cluster`, `remote-node`...) or `fromEndpoints` with labels, and no `toPorts`. The only `toPorts` is the DNS rule of an FQDN egress, which Cilium requires to see the answers. A port that changes with an upgrade then breaks nothing, and a pod only exposes the ports it listens on. Only the host firewall (`cilium/policies/host.yaml`) filters by port, the ports of the nodes being fixed.
- Labels that stay stable across upgrades (`app.kubernetes.io/name`, the labels set by the repository), and `io.kubernetes.pod.namespace` to select a pod of another namespace.
- A policy for pods created by an operator goes next to the resource that defines them (`linstor-controller` next to the `LinstorCluster`).
- No Kubernetes `NetworkPolicy`: Cilium applies them too, and a flow allowed by one of them passes over the baseline. Disable the ones a chart creates in its values (as `flux-operator` and `flux-instance`).

```yaml
---
# <client> (namespace <namespace>) calls the API of <app>.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: <app>
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: <app>
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: <namespace>
            app.kubernetes.io/name: <client>
```

An egress to a device of the internal network, by name (`<device>.shelltopia.net` is a placeholder). Not tested yet:

```yaml
---
# <app> reads <device> (internal network): by name, never by address. The DNS rule lets Cilium
# learn the addresses of the name from the answers of CoreDNS.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: <app>-<device>
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: <app>
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchName: <device>.shelltopia.net
    - toFQDNs:
        - matchName: <device>.shelltopia.net
```

### Pod security

A namespace is `restricted` unless stated otherwise ([cluster](cluster/README.md#pod-security)), and Pod Security refuses a pod that does not meet it.

- Prefer an image that runs as non-root. The UID and GID of the application are set in the manifest, and its data on the NAS or in a restored volume belongs to them (`chown` once at the migration).
- The security context below, in the manifest or the values of the chart. `readOnlyRootFilesystem` is not required by `restricted`, but set whenever the application allows it, with an `emptyDir` for the paths it writes (`/tmp`).
- A NAS share goes through a static PersistentVolume and its PersistentVolumeClaim, never an inline `nfs` volume ([storage](storage/runbook.md#mounting-a-nas-share)).
- An application that cannot run `restricted`: try `hostUsers: false` first, then a namespace at `baseline` ([runbook](cluster/runbook.md#pod-security)).
- The test pods (`kubectl run`) go in the `debug` namespace, and are deleted after use.

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: <app>
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

### Secrets

- Never in Git: an `ExternalSecret` next to the application, `secretStoreRef` on the `onepassword` `ClusterSecretStore`, `remoteRef.key: <item>/<field>` ([secrets](secrets/README.md#in-the-cluster-external-secrets)).
- A long `refreshInterval` (`1h`, `12h` for VolSync): the service account has rate limits.
- One item and one token per tool, so that a leaked one gives no access to the others, named `<provider>-<app>` or `<host>-<service>` (`cloudflare-external-dns`, `sw-01-snmp`: [naming](secrets/README.md#naming-of-the-items)). Items of the cluster in the `kubernetes` vault, the rest in `infrastructure` ([reference](reference.md#1password-items)).

### Reloads

- A workload that only reads a ConfigMap or Secret at startup (env var, `subPath` mount, configuration read once) carries `reloader.stakater.com/auto: "true"` on its own `metadata` (Deployment, StatefulSet, DaemonSet), not on the pod template: Reloader restarts it when the content changes ([cluster](cluster/README.md#reloader)). With a chart, through its value for the annotations of the workload (`deploymentAnnotations` for external-dns).
- A comment next to the annotation says what it reloads.
- Nothing for Jobs and CronJobs, nor for an application that watches its mounted files itself; a reference it reloads by itself is excluded with `secrets.exclude.reloader.stakater.com/reload` (or `configmaps.exclude.…`).

### Routes and names

- A route lists its `hostnames` and its `parentRefs`: the DNS records are created from them ([dns](dns/README.md#overview)). Applications are served in `shelltopia.org`, as `<appname>.shelltopia.org` where `<appname>` is the name of the application (its folder in `kubernetes/apps`): `grafana.shelltopia.org`.
- A public route is attached to both Gateways ([ingress](ingress/runbook.md#exposing-an-application)).
- A volume to back up goes through the `volsync` component, one volume per application ([backups](backups/runbook.md#backing-up-an-application)).

### LoadBalancer addresses

- Every LoadBalancer Service pins its addresses, IPv4 and IPv6, with the `lbipam.cilium.io/ips` annotation, in its pool. Cilium LB IPAM gives a Service without annotation the lowest free address, which can be the one that another Service pins: that one then gets no address at all. And what points to these addresses (Unbound, the OPNsense rules, the devices, the DNS records) needs them stable.
- The addresses are allocated in the [reference](reference.md#pinned-loadbalancer-addresses), updated in the same commit. The same host part in both families (`192.168.19.2` and `fd38:4c4d:8f66:13::2`). Check that a new address is free first: `kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide`.
- A comment next to the annotation says what depends on the addresses, to update with them.
- The name of a receiver of the infrastructure (the devices send to it) is `<service>.kube-cluster01.shelltopia.net`, `A` and `AAAA` host overrides in Unbound, created by hand and kept in sync with the addresses ([dns](dns/runbook.md#where-to-create-a-record)). The names of the applications stay in `shelltopia.org`, served from the routes.
- The GUA addresses of the `external` pool are pinned too. They are in the stable Milkywan /48 and do not change with the ISP prefix ([network](network/milkywan.md)).

## Talos

- Plain machine config documents. Common settings in `talos/patches/`, hardware settings in `talos/nodes/<node>.yaml`, versions and shared values in `talos/vars.yaml` with a `# renovate:` comment on the line before each version.
- A 1Password reference (`op://...`) only in a `.yaml.j2` patch, never in a comment ([gotchas](../talos/README.md#gotchas)).
- Everything dynamic, nothing hardcoded that the network can give: FQDN rather than address ([network](network/README.md#principles)). The LoadBalancer addresses of the cluster are the exception, all pinned ([above](#loadbalancer-addresses)).
- No search domain on the nodes, so none in the pods: always an FQDN, never a short name ([network](network/README.md#nodes-subnet)).
- After a refactoring that should not change anything, `just talos diff` is empty on every node ([checking a change](../talos/README.md#checking-a-change)).

## OpenTofu

States in B2, encrypted. Keys of the buckets are pushed to the 1Password items by `just tofu apply`. Records owned by a tool of the cluster are never added to a stack ([dns](dns/runbook.md#where-to-create-a-record)).

## Documentation

- One folder per topic, the same files in each: `README.md`, `bootstrap.md`, `runbook.md`, `evaluations.md` ([format](README.md#format)).
- A procedure is a list of steps: a checkbox, a bold title ending with a period, the command in a `sh` code block, then an `Expected:` paragraph with what to see. The checkbox is ticked once the step was done.
- The decisions live in the `README.md` of their topic, the rejected options and the open points in `evaluations.md`: the [roadmap](roadmap.md) only points to them.
- A procedure that was not run says so (*Not tested yet*).
- Comments in manifests, recipes and templates say why, and point to the document of the topic.
