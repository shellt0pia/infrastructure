# Talos

Machine configs of the cluster nodes, rendered by `just talos render-config <node>` and applied by `just talos apply-node <node>`. Run `just talos` to list the recipes.

| Path | Content |
| --- | --- |
| `vars.yaml` | Variables shared by the templates (minijinja) and the recipes (yq): domain, cluster, network, versions, node list. |
| `schematic.yaml` | Image Factory schematic (extensions, kernel arguments, Secure Boot). Its ID selects the installer image and the ISO. |
| `patches/` | Patches common to all the nodes, including the hostname (`hostname.yaml.j2`). |
| `nodes/<node>.yaml` | Hardware-specific patches of a node (plain YAML): disks, NIC, labels. |

## Render layers

`render-config` builds the config with `talosctl gen config`, in this order (a later layer overrides an earlier one):

1. The base config generated from the secrets bundle (`op://infrastructure/talos-secrets`, see `gen-secrets`), the cluster name and endpoint, the Talos and Kubernetes versions of `vars.yaml` and the installer image of the schematic.
2. `patches/controlplane-reset.yaml`, on its own (see below).
3. The other `patches/*.yaml`, used as is, in alphabetical order.
4. `patches/*.yaml.j2`, in alphabetical order, rendered by `just template`: minijinja with `vars.yaml` and `-D node=<node>`, then `op inject` resolves the 1Password references.
5. `nodes/<node>.yaml`, used as is: no template and no 1Password reference in the node files.

The rendered config contains the cluster PKI: never write it into the repository.

## Gotchas

- A patch file cannot modify the same document twice. That is why `controlplane-reset.yaml` (which deletes the default labels and taints) is applied before `kubernetes.yaml.j2` (which adds the labels back).
- `$patch: delete` on a single dotted key fails (`lookup failed`): delete the whole map, then add back what must be kept.
- minijinja runs in strict mode (`.minijinja.toml`): an undefined variable is an error, not an empty string.
- `op inject` resolves every reference of the rendered output, comments included: never write a 1Password reference in a template comment.
- `op inject` does not end a bare reference at a space: it must be followed by a quote or the end of the line. Otherwise use the enclosed syntax, escaped for minijinja (see `vars.yaml` and `patches/extensions.yaml.j2`).
- Adding a node: add it to `nodes` in `vars.yaml` and create `nodes/<node>.yaml`. The first node of the list is used for the one-shot operations (etcd bootstrap, kubeconfig, `upgrade-k8s`).

## Checking a change

- `talosctl validate --mode metal --strict --config <(just talos render-config <node>)` checks the rendered config without touching the node.
- `just talos apply-node <node> --dry-run` shows the diff with the running config. After a refactor that should not change anything (moving a setting between patches, renaming a variable...), the diff must be empty on every node.
