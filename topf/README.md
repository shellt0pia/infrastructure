# topf

Evaluation of [topf](https://postfinance.github.io/topf) as a replacement for the `talos` module: same machine configs, rendered and applied by topf instead of `talosctl gen config` + minijinja + `op inject`. Run `just topf` to list the recipes. The `bootstrap` module still uses the `talos` module.

| Path | Content |
| --- | --- |
| `topf.yaml` | Cluster, versions, schematic, template data (`data`) and nodes. |
| `schematic.yaml` | Image Factory schematic (extensions, Secure Boot). Its ID is computed locally by topf. |
| `secrets-provider` | Prints the Talos secrets bundle stored in 1Password (`op://infrastructure/talos-secrets`). |
| `all/` | Patches common to all the nodes. |
| `node/<host>/` | Hardware-specific patches of a node: disks, NIC, labels. |

## Render layers

topf builds the config of each node in this order (a later patch overrides an earlier one):

1. The base config generated from the secrets bundle, the cluster name and endpoint, the versions, and the installer image of the schematic (`secureboot: true`).
2. `all/`, then `control-plane/` (unused), then `node/<host>/`, each in alphabetical order. Every YAML document is a separate patch.

`.yaml.tpl` files are Go templates ([sprig](https://masterminds.github.io/sprig/) functions, an undefined key is an error) with `.Data` (`data` of `topf.yaml`) and `.Node.Host` (the FQDN).

## Secrets

Nothing is written to disk, everything is read from 1Password with the workstation service account (docs/1password-local-access.md) for each command:

- **Secrets bundle:** `secrets-provider secrets get`, i.e. `op document get`. `put` is refused: topf would otherwise generate and store a new bundle when the item is missing. Use `just topf gen-secrets`.
- **Plain values** (Docker Hub in `all/containerd.yaml`): `ref+op://vault/item/field`, resolved by [vals](https://github.com/helmfile/vals) and masked in the diffs.
- **Values embedded in a text block** (NUT credentials in `all/extensions.yaml.tpl`): read by `just topf run` and passed in the environment of topf (`NUT_USERNAME`, `NUT_PASSWORD`), read by the template with `env`. They are **not** masked in the diffs.

The last case is needed because topf only runs vals on non-template files containing at least one value that **starts** with `ref+`. vals itself resolves an embedded reference ending with a `+` (`text ref+op://vault/item/field+ text`), but only if another value of the same file triggers it, and topf does not mask it: an environment variable is more robust.

## Differences with the talos module

- `apply` and `upgrade` work on all the nodes (`--nodes-filter <regex>` to restrict them), show the diff and ask before each node. `upgrade` cordons, drains, reboots and uncordons the nodes one at a time and skips the nodes already up to date.
- No `controlplane-reset.yaml` applied apart: since every document is a separate patch, the default labels and taints are deleted by the first document of `all/kubernetes.yaml.tpl`.
- The hostname is set once for all the nodes (`all/hostname.yaml.tpl`): the node files are plain YAML.
- Still done with talosctl: `upgrade-k8s` (topf has no Kubernetes upgrade), `reset-node` (`topf reset` cannot wipe the `r-storage` volume), `reboot-node` and `shutdown-node`.
- topf embeds the Talos machinery of its own release (`topf --version`), possibly older than the cluster: its support of a new Talos version depends on a topf release.

## Checking a change

- `just topf render-config <node>` prints the rendered config (it contains the cluster PKI).
- `just topf apply --dry-run` shows the diff with the running config of every node, and exits with code 2 if there are changes.
