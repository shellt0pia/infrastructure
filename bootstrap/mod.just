set default-list
set default-script
set lazy
set no-exit-message
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
cluster: talosconfig nodes etcd kubeconfig api-ready nodes-ready secrets apps

[doc('Generate the talosconfig client file')]
talosconfig:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    if ! {{ just }} talos talosconfig; then
        {{ just }} log fatal "Failed to generate the talosconfig" stage "{{ recipe_name() }}"
    fi

[doc('Apply the machine config to all the nodes in maintenance mode')]
nodes:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    for node in $(yq -r '.nodes[]' '{{ vars }}'); do
        {{ just }} log info "Applying the machine config" stage "{{ recipe_name() }}" node "$node"
        if ! output="$({{ just }} --yes talos apply-node "$node" --insecure 2>&1)"; then
            if [[ "$output" == *"certificate required"* ]]; then
                {{ just }} log info "Already configured, skipping" stage "{{ recipe_name() }}" node "$node"
                continue
            fi
            {{ just }} log fatal "Failed to apply the machine config" stage "{{ recipe_name() }}" node "$node" output "$output"
        fi
    done

[doc('Bootstrap etcd on the first node')]
etcd:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    mapfile -t fqdns < <({{ just }} talos node-fqdns)
    until output="$(talosctl --nodes "${fqdns[0]}" bootstrap 2>&1)" || [[ "$output" == *"AlreadyExists"* ]]; do
        {{ just }} log info "Waiting for the node to be ready to bootstrap etcd..." stage "{{ recipe_name() }}" reason "${output##*desc = }"
        sleep 10
    done

[doc('Fetch the admin kubeconfig at the repository root')]
kubeconfig:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    mapfile -t fqdns < <({{ just }} talos node-fqdns)
    until talosctl --nodes "${fqdns[0]}" kubeconfig --force --force-context-name '{{ cluster_name }}' "$KUBECONFIG"; do
        {{ just }} log info "Waiting for the kubeconfig to be available..." stage "{{ recipe_name() }}"
        sleep 10
    done

# Anonymous requests to /readyz are allowed by default. helmfile and kubectl are not retried
# afterwards: every API server must answer first.
[doc('Wait for the API server of every node to be ready')]
api-ready:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    mapfile -t fqdns < <({{ just }} talos node-fqdns)
    for fqdn in "${fqdns[@]}"; do
        until [[ "$(curl --insecure --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 2 "https://$fqdn:6443/readyz")" == 200 ]]; do
            {{ just }} log info "Waiting for the API server..." stage "{{ recipe_name() }}" node "$fqdn"
            sleep 5
        done
    done

# The nodes stay NotReady until the CNI is installed by the `apps` recipe: wait for their
# registration only. The node names are the short hostnames.
[doc('Wait for all the nodes to register')]
nodes-ready:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    mapfile -t nodes < <(yq -r '.nodes[] | "node/" + .' '{{ vars }}')
    until kubectl wait "${nodes[@]}" --for=create --timeout=10s >/dev/null 2>&1; do
        {{ just }} log info "Waiting for the nodes to register..." stage "{{ recipe_name() }}"
        sleep 5
    done

[doc('Create the secrets needed before External Secrets and Flux are running')]
secrets:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    if ! {{ just }} template '{{ source_directory() }}/resources/secrets.yaml.j2' | kubectl apply --server-side --filename -; then
        {{ just }} log fatal "Failed to apply the secrets" stage "{{ recipe_name() }}"
    fi

[doc('Install the bootstrap apps with helmfile, Flux takes over afterwards')]
[working-directory('helmfile')]
apps:
    {{ just }} log info "Running stage..." stage "{{ recipe_name() }}"
    if ! helmfile --file apps.yaml.gotmpl sync --hide-notes; then
        {{ just }} log fatal "Failed to sync the bootstrap apps" stage "{{ recipe_name() }}"
    fi
