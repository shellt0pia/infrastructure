set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

export TALOSCONFIG := justfile_directory() / "talosconfig"
export KUBECONFIG := justfile_directory() / "kubeconfig"

just := quote(just_executable()) + " --justfile " + quote(justfile())
vars := justfile_directory() / "talos" / "vars.yaml"
cluster_name := shell('yq -r ".cluster.name" "$1"', vars)

[doc('Bootstrap the cluster from nodes booted in maintenance mode up to Flux')]
[confirm('Bootstrap the cluster ' + cluster_name + '? [y/N]')]
cluster: talosconfig nodes etcd kubeconfig wait-nodes secrets apps

[doc('Generate the talosconfig client file')]
talosconfig:
    {{ just }} talos talosconfig

[doc('Apply the machine config to all the nodes in maintenance mode')]
nodes:
    for node in $(yq -r '.nodes[]' '{{ vars }}'); do
        echo "Applying the machine config to $node"
        if ! output="$({{ just }} --yes talos apply-node "$node" --insecure 2>&1)"; then
            if [[ "$output" == *"certificate required"* ]]; then
                echo "$node is already configured, skipping"
                continue
            fi
            echo "$output" >&2
            exit 1
        fi
    done

[doc('Bootstrap etcd on the first node')]
etcd:
    mapfile -t fqdns < <({{ just }} talos node-fqdns)
    until output="$(talosctl --nodes "${fqdns[0]}" bootstrap 2>&1)" || [[ "$output" == *"AlreadyExists"* ]]; do
        echo "Waiting for the node to be ready to bootstrap etcd: ${output##*desc = }"
        sleep 10
    done

[doc('Fetch the admin kubeconfig at the repository root')]
kubeconfig:
    mapfile -t fqdns < <({{ just }} talos node-fqdns)
    until talosctl --nodes "${fqdns[0]}" kubeconfig --force --force-context-name '{{ cluster_name }}' "$KUBECONFIG"; do
        echo "Waiting for the kubeconfig to be available..."
        sleep 10
    done

# The nodes stay NotReady until the CNI is installed by the `apps` recipe.
[doc('Wait for all the nodes to register')]
wait-nodes:
    expected="$(yq -r '.nodes | length' '{{ vars }}')"
    until [[ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -eq "$expected" ]]; do
        echo "Waiting for the $expected nodes to register..."
        sleep 10
    done

[doc('Create the secrets needed before External Secrets and Flux are running')]
secrets:
    {{ just }} template '{{ source_directory() }}/resources/secrets.yaml.j2' | kubectl apply --server-side --filename -

[doc('Install the bootstrap apps with helmfile, Flux takes over afterwards')]
[working-directory('helmfile')]
apps:
    helmfile --file apps.yaml.gotmpl sync --hide-notes
