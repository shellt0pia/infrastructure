set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

export TALOSCONFIG := justfile_directory() / "talosconfig"

just := quote(just_executable()) + " --justfile " + quote(justfile())
vars := source_directory() / "vars.yaml"

# 1Password location of the Talos secrets bundle (cluster PKI, tokens...).
# Keep it out of the vault readable by External Secrets.
op_vault := "infrastructure"
op_item := "talos-secrets"
op_secrets_ref := "op://" + op_vault + "/" + op_item + "/secrets.yaml"

[doc('Generate the cluster secrets bundle and store it in 1Password (one-time operation)')]
gen-secrets:
    op vault get '{{ op_vault }}' >/dev/null
    if op document get '{{ op_item }}' --vault '{{ op_vault }}' >/dev/null 2>&1; then
        echo "op://{{ op_vault }}/{{ op_item }} already exists, refusing to overwrite it." >&2
        exit 1
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    talosctl gen secrets --output-file "$tmp/secrets.yaml"
    op document create "$tmp/secrets.yaml" --title '{{ op_item }}' --vault '{{ op_vault }}' --file-name secrets.yaml >/dev/null
    echo "Secrets bundle stored in op://{{ op_vault }}/{{ op_item }}"

[doc('Get the Image Factory schematic ID of schematic.yaml')]
schematic-id:
    curl --fail --silent --show-error --request POST --data-binary '@{{ source_directory() }}/schematic.yaml' https://factory.talos.dev/schematics | jq --raw-output '.id'

# Patches: patches/controlplane-reset.yaml first (it modifies a document also patched by
# kubernetes.yaml.j2), then the other files of patches/, then nodes/<node>.yaml.j2.
# `*.yaml` files are used as is, `*.j2` files are rendered with minijinja.
# The secrets bundle and the `op://` references of all the rendered templates are resolved by a
# single `op inject` call, so 1Password asks for one authorization only: their unresolved
# contents are concatenated, each one after a `#@@ <file name> @@` line, then split again.
[doc('Render the machine config of a node to stdout')]
render-config node:
    {{ just }} talos node-fqdn '{{ node }}' >/dev/null
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    mkdir "$tmp/resolved"
    patches=(--config-patch '@{{ source_directory() }}/patches/controlplane-reset.yaml')
    for file in '{{ source_directory() }}'/patches/*.yaml; do
        [[ "$file" == */controlplane-reset.yaml ]] || patches+=(--config-patch "@$file")
    done
    {
        printf '#@@ secrets.yaml @@\n{{{{ %s }}\n' '{{ op_secrets_ref }}'
        for file in '{{ source_directory() }}'/patches/*.yaml.j2 '{{ source_directory() }}/nodes/{{ node }}.yaml.j2'; do
            name="$(basename "$file" .j2)"
            printf '\n#@@ %s @@\n' "$name"
            {{ just }} render "$file" -D 'node={{ node }}'
            patches+=(--config-patch "@$tmp/resolved/$name")
        done
    } > "$tmp/unresolved"
    op inject --in-file "$tmp/unresolved" | awk -v dir="$tmp/resolved" '/^#@@ .+ @@$/ { file = dir "/" $2; printf "" > file; next } { print > file }'
    image="$({{ just }} talos installer-image)"
    {{ just }} talos gen-config "$tmp/resolved/secrets.yaml" \
        --output-types controlplane \
        --install-image "$image" \
        --with-docs=false \
        --with-examples=false \
        "${patches[@]}" \
        --output -

[doc('Apply the machine config to a node, e.g. `just talos apply-node kube-01 --insecure` (maintenance mode) or `--dry-run`')]
[confirm('Apply the machine config?')]
apply-node node *args:
    fqdn="$({{ just }} talos node-fqdn '{{ node }}')"
    config="$({{ just }} talos render-config '{{ node }}')"
    talosctl --nodes "$fqdn" apply-config --file /dev/stdin {{ args }} <<< "$config"

[doc('Generate the talosconfig client file at the repository root')]
talosconfig:
    secrets="$(mktemp)"
    trap 'rm -f "$secrets"' EXIT
    op document get '{{ op_item }}' --vault '{{ op_vault }}' > "$secrets"
    {{ just }} talos gen-config "$secrets" --output-types talosconfig --output "$TALOSCONFIG" --force
    mapfile -t fqdns < <({{ just }} talos node-fqdns)
    talosctl config endpoint "${fqdns[@]}"
    talosctl config node "${fqdns[0]}"
    echo "talosconfig written to $TALOSCONFIG"

[doc('Upgrade Talos on a node to the version and schematic of the repository')]
[confirm('Upgrade Talos on this node?')]
upgrade-node node *args:
    fqdn="$({{ just }} talos node-fqdn '{{ node }}')"
    image="$({{ just }} talos installer-image)"
    talosctl --nodes "$fqdn" upgrade --image "$image" {{ args }}

[doc('Upgrade Kubernetes to the version of the repository, e.g. `just talos upgrade-k8s --dry-run`')]
upgrade-k8s *args:
    mapfile -t fqdns < <({{ just }} talos node-fqdns)
    version="$(yq -r '.kubernetes_version' '{{ vars }}')"
    talosctl --nodes "${fqdns[0]}" upgrade-k8s --to "${version#v}" --with-docs=false --with-examples=false {{ args }}

[doc('Reboot a node')]
[confirm('Reboot this node?')]
reboot-node node:
    talosctl --nodes "$({{ just }} talos node-fqdn '{{ node }}')" reboot

[doc('Reset a node: it leaves the cluster, wipes its data and reboots in maintenance mode')]
[confirm('Reset this node? ALL ITS DATA WILL BE LOST.')]
reset-node node:
    # r-storage (NVMe raw volume) is locked to STATE: it would be unreadable after the reset anyway.
    talosctl --nodes "$({{ just }} talos node-fqdn '{{ node }}')" reset --graceful --reboot --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --system-labels-to-wipe r-storage

[doc('Download the Secure Boot Talos ISO matching schematic.yaml and the Talos version')]
download-image:
    schematic="$({{ just }} talos schematic-id)"
    version="$(yq -r '.talos_version' '{{ vars }}')"
    curl --fail --location --progress-bar \
        --output '{{ source_directory() }}/talos-'"$version"'-amd64-secureboot.iso' \
        "https://factory.talos.dev/image/$schematic/$version/metal-amd64-secureboot.iso"

# FQDN of a node of vars.yaml (`<node>.<domain>`), the name used to reach it.
[private]
node-fqdn node:
    yq -e -r '.domain as $domain | .nodes[] | select(. == "{{ node }}") | . + "." + $domain' '{{ vars }}' || { echo "Unknown node '{{ node }}', see {{ vars }}" >&2; exit 1; }

# FQDNs of all the nodes of vars.yaml, in order.
[private]
node-fqdns:
    yq -r '.domain as $domain | .nodes[] | . + "." + $domain' '{{ vars }}'

[private]
installer-image:
    schematic="$({{ just }} talos schematic-id)"
    version="$(yq -r '.talos_version' '{{ vars }}')"
    echo "factory.talos.dev/metal-installer-secureboot/$schematic:$version"

# Wrapper around `talosctl gen config` feeding the secrets bundle (a file already fetched from
# 1Password by the caller) and the versions.
[private]
gen-config secrets *args:
    name="$(yq -r '.cluster.name' '{{ vars }}')"
    endpoint="$(yq -r '.cluster.endpoint' '{{ vars }}')"
    talos_version="$(yq -r '.talos_version' '{{ vars }}')"
    kubernetes_version="$(yq -r '.kubernetes_version' '{{ vars }}')"
    talosctl gen config "$name" "$endpoint" \
        --with-secrets '{{ secrets }}' \
        --talos-version "$talos_version" \
        --kubernetes-version "$kubernetes_version" \
        {{ args }}
