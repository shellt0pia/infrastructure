# Conventions

How the repository is organised and the habits that the manifests, the Talos configuration and the documentation follow, so that a new application or setting looks like the others. The topics explain why each part exists, this page only collects the rules. An example of every pattern is the `kubernetes/apps/cert-manager` and `kubernetes/apps/network` folders.

## Layout

| Path | Content |
| --- | --- |
| `talos/` | The machine configs of the nodes, [render layers](../talos/README.md#render-layers) |
| `bootstrap/` | `just bootstrap cluster`: the stages up to Flux, [cluster](cluster/README.md#overview) |
| `kubernetes/apps/` | Everything Flux deploys, one folder per namespace |
| `kubernetes/components/` | Kustomize components shared by the applications, such as `volsync` |
| `kubernetes/mod.just` | The `just kube` recipes of the workstation |
| `tofu/` | OpenTofu stacks: `cloudflare` and `backblaze`, [tofu/README.md](../tofu/README.md) |
| `docs/` | This documentation, [format](README.md#format) |

Every `just` module (`talos`, `bootstrap`, `tofu`, `kube`) lists its recipes with `just <module>`, each recipe has a `[doc]`.

## Flux applications

Flux follows `kubernetes/apps` (`sync.path` of the `flux-instance` HelmRelease). Each namespace is a folder:

```text
kubernetes/apps/<namespace>/
├── kustomization.yaml        # namespace.yaml and the ks.yaml of every application
├── namespace.yaml
└── <app>/
    ├── ks.yaml               # the Flux Kustomization(s) of the application
    └── app/                  # what it deploys
        ├── kustomization.yaml
        ├── ocirepository.yaml
        ├── helmrelease.yaml
        └── externalsecret.yaml
```

`kustomization.yaml` of the namespace sets `namespace:`, and each `ks.yaml` sets `targetNamespace`: the manifests of `app/` never repeat it.

### Flux Kustomizations

- `interval: 1h`, `prune: true`, `sourceRef` to `flux-system`, `wait: true`: a Kustomization is `Ready` once what it deploys is.
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
- `kube-system` is created by Kubernetes and not managed.
- A namespace whose pods need it carries the Pod Security labels (`piraeus-datastore`: privileged).
- A namespace whose applications are exposed on the internet carries `shelltopia.net/gateway-external: "true"` ([ingress](ingress/runbook.md#exposing-an-application)).

### Secrets

- Never in Git: an `ExternalSecret` next to the application, `secretStoreRef` on the `onepassword` `ClusterSecretStore`, `remoteRef.key: <item>/<field>` ([secrets](secrets/README.md#in-the-cluster-external-secrets)).
- A long `refreshInterval` (`1h`, `12h` for VolSync): the service account has rate limits.
- One item and one token per tool, so that a leaked one gives no access to the others. Items of the cluster in the `kubernetes` vault, the rest in `infrastructure` ([reference](reference.md#1password-items)).

### Routes and names

- A route lists its `hostnames` and its `parentRefs`: the DNS records are created from them ([dns](dns/README.md#overview)). Applications are served in `shelltopia.org`.
- A public route is attached to both Gateways ([ingress](ingress/runbook.md#exposing-an-application)).
- A volume to back up goes through the `volsync` component, one volume per application ([backups](backups/runbook.md#backing-up-an-application)).

## Talos

- Plain machine config documents. Common settings in `talos/patches/`, hardware settings in `talos/nodes/<node>.yaml`, versions and shared values in `talos/vars.yaml` with a `# renovate:` comment on the line before each version.
- A 1Password reference (`op://...`) only in a `.yaml.j2` patch, never in a comment ([gotchas](../talos/README.md#gotchas)).
- Everything dynamic, nothing hardcoded that the network can give: FQDN rather than address ([network](network/README.md#principles)).
- After a refactoring that should not change anything, `just talos diff` is empty on every node ([checking a change](../talos/README.md#checking-a-change)).

## OpenTofu

States in B2, encrypted. Keys of the buckets are pushed to the 1Password items by `just tofu apply`. Records owned by a tool of the cluster are never added to a stack ([dns](dns/runbook.md#where-to-create-a-record)).

## Documentation

- One folder per topic, the same files in each: `README.md`, `bootstrap.md`, `runbook.md`, `evaluations.md` ([format](README.md#format)).
- A procedure is a list of steps: a checkbox, a bold title ending with a period, the command in a `sh` code block, then an `Expected:` paragraph with what to see. The checkbox is ticked once the step was done.
- The decisions live in the `README.md` of their topic, the rejected options and the open points in `evaluations.md`: the [roadmap](roadmap.md) only points to them.
- A procedure that was not run says so (*Not tested yet*).
- Comments in manifests, recipes and templates say why, and point to the document of the topic.
