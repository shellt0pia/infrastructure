set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# The recipes run from this directory: topf finds topf.yaml and ./secrets-provider there.
export TALOSCONFIG := justfile_directory() / "talosconfig"

just := quote(just_executable()) + " --justfile " + quote(justfile())
config := source_directory() / "topf.yaml"

# 1Password location of the Talos secrets bundle (cluster PKI, tokens...), also in secrets-provider.
# Keep it out of the vault readable by External Secrets.
op_vault := "infrastructure"
op_item := "talos-secrets"

# The personal account, through the desktop app on the host: `op` in the toolbox uses the
# workstation service account, which is read-only (docs/1password-local-access.md).
op_personal := "host-spawn op"

# The NUT credentials are embedded in a text block that vals cannot resolve: they are passed to
# the templates in the environment, see README.md.
[doc('Run topf with the 1Password values of the templates, e.g. `just topf run apply --dry-run`')]
run *args:
    nut_username="$(op read 'op://infrastructure/nut-server/username')"
    nut_password="$(op read 'op://infrastructure/nut-server/password')"
    NUT_USERNAME="$nut_username" NUT_PASSWORD="$nut_password" topf {{ args }}

[doc('Generate the cluster secrets bundle and store it in 1Password (one-time operation)')]
gen-secrets:
    {{ op_personal }} vault get '{{ op_vault }}' >/dev/null
    if {{ op_personal }} document get '{{ op_item }}' --vault '{{ op_vault }}' >/dev/null 2>&1; then
        echo "op://{{ op_vault }}/{{ op_item }} already exists, refusing to overwrite it." >&2
        exit 1
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    talosctl gen secrets --output-file "$tmp/secrets.yaml"
    # Read by the host process: /tmp is shared between the host and the toolbox.
    {{ op_personal }} document create "$tmp/secrets.yaml" --title '{{ op_item }}' --vault '{{ op_vault }}' --file-name secrets.yaml >/dev/null
    echo "Secrets bundle stored in op://{{ op_vault }}/{{ op_item }}"

# topf computes the ID locally: a new schematic must be registered once, which this POST does.
[doc('Register schematic.yaml with the Image Factory and print its ID')]
schematic-id:
    curl --fail --silent --show-error --request POST --data-binary '@{{ source_directory() }}/schematic.yaml' https://factory.talos.dev/schematics | jq --raw-output '.id'

[doc('Render the machine config of a node to stdout')]
render-config node:
    host="$({{ just }} topf node-fqdn '{{ node }}')"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    {{ just }} topf run render --nodes-filter "^$host\$" --output "$tmp" >&2
    cat "$tmp/$host.yaml"

[doc('Apply the machine configs, shows the diff and asks before each node, e.g. `just topf apply --nodes-filter kube-01 --dry-run`')]
apply *args:
    {{ just }} topf run apply {{ args }}

[doc('Upgrade Talos to the version and schematic of topf.yaml, one node at a time (drain, reboot, uncordon)')]
upgrade *args:
    {{ just }} topf run upgrade {{ args }}

[doc('Generate the talosconfig client file at the repository root')]
talosconfig:
    config="$({{ just }} topf run talosconfig)"
    (umask 077 && printf '%s\n' "$config" > "$TALOSCONFIG")
    # topf targets all the nodes by default: target the first one only, like `talosctl gen config`.
    talosctl config node "$(yq -r '.nodes[0].host' '{{ config }}')"
    echo "talosconfig written to $TALOSCONFIG"

[doc('Upgrade Kubernetes to the version of topf.yaml, e.g. `just topf upgrade-k8s --dry-run`')]
upgrade-k8s *args:
    host="$(yq -r '.nodes[0].host' '{{ config }}')"
    version="$(yq -r '.kubernetesVersion' '{{ config }}')"
    talosctl --nodes "$host" upgrade-k8s --to "${version#v}" --with-docs=false --with-examples=false {{ args }}

[doc('Reboot a node')]
[confirm('Reboot ' + node + '? [y/N]')]
reboot-node node:
    talosctl --nodes "$({{ just }} topf node-fqdn '{{ node }}')" reboot

[doc('Shut a node down after cordoning and draining it, `--force` skips both')]
[confirm('Shut ' + node + ' down? [y/N]')]
shutdown-node node *args:
    talosctl --nodes "$({{ just }} topf node-fqdn '{{ node }}')" shutdown {{ args }}

# `topf reset` can only wipe STATE and EPHEMERAL, or the whole disks.
[doc('Reset a node: it leaves the cluster, wipes its data and reboots in maintenance mode')]
[confirm('Reset ' + node + '? ALL ITS DATA WILL BE LOST. [y/N]')]
reset-node node:
    # r-storage (NVMe raw volume) is locked to STATE: it would be unreadable after the reset anyway.
    talosctl --nodes "$({{ just }} topf node-fqdn '{{ node }}')" reset --graceful --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --system-labels-to-wipe r-storage

# The schematic prefix in the file name tells ISOs of the same version apart.
[doc('Download the Secure Boot Talos ISO matching schematic.yaml and the Talos version')]
download-image:
    schematic="$({{ just }} topf schematic-id)"
    version="$(yq -r '.talosVersion' '{{ config }}')"
    curl --fail --location --progress-bar \
        --retry 5 --retry-delay 5 --retry-all-errors --remove-on-error \
        --output '{{ source_directory() }}/talos-'"$version-${schematic:0:8}"'-amd64-secureboot.iso' \
        "https://factory.talos.dev/image/$schematic/$version/metal-amd64-secureboot.iso"

# FQDN (`host` in topf.yaml) of a node given by its short name.
[private]
node-fqdn node:
    yq -e -r '.nodes[].host | select(split(".")[0] == "{{ node }}")' '{{ config }}' || { echo "Unknown node '{{ node }}', see {{ config }}" >&2; exit 1; }
