set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

just := quote(just_executable()) + " --justfile " + quote(justfile())

# Environment of every stack (backend, state encryption), then the provider credentials of the
# stack, both resolved with the workstation service account (docs/1password-local-access.md).
[doc('Run any tofu command on a stack, e.g. `just tofu run cloudflare state list`')]
run stack *args:
    op run --env-file='{{ source_directory() }}/op.env' --env-file='{{ source_directory() }}/{{ stack }}/op.env' -- tofu -chdir='{{ source_directory() }}/{{ stack }}' {{ args }}

[doc('Initialize a stack (backend, providers, lock file), add `-reconfigure` after a change of backend.hcl')]
init stack *args: (run stack "init" "-backend-config=" + source_directory() + "/backend.hcl" args)

[doc('Show the changes of a stack')]
plan stack *args: (run stack "plan" args)

[doc('Apply the changes of a stack, then push its `onepassword_items` output to 1Password')]
apply stack *args: (run stack "apply" args) && (sync-1password stack)

# Creates or updates the items listed in the `onepassword_items` output of a stack (B2 application
# keys of the backblaze stack), does nothing for a stack without it.
# The workstation service account only reads: it finds the items and compares their values. The
# writes go through the personal account (`host-spawn op`), one approval per created or changed
# item, none when everything is up to date. The values only go through pipes, never through
# command arguments (/proc/<pid>/cmdline is world-readable) nor files.
[doc('Push the `onepassword_items` output of a stack to 1Password (run by `apply`)')]
sync-1password stack:
    stack='{{ stack }}'
    outputs="$({{ just }} tofu run "$stack" output -json)"
    count="$(printf '%s' "$outputs" | jq '.onepassword_items.value // [] | length')"
    for ((i = 0; i < count; i++)); do
        wanted="$(printf '%s' "$outputs" | jq --compact-output --argjson i "$i" '.onepassword_items.value[$i]')"
        vault="$(printf '%s' "$wanted" | jq --raw-output '.vault')"
        title="$(printf '%s' "$wanted" | jq --raw-output '.item')"

        matches="$(op item list --vault "$vault" --format json </dev/null | jq --arg title "$title" '[.[] | select(.title == $title)] | length')"
        if ((matches > 1)); then
            {{ just }} log fatal "Several items with this title, keep only one" vault "$vault" item "$title"
        elif ((matches == 0)); then
            {{ just }} log info "Creating the item (1Password approval)" vault "$vault" item "$title"
            create=(host-spawn op item create --vault "$vault" --category password --title "$title")
            if [[ "$(printf '%s' "$wanted" | jq '.generate_password')" == true ]]; then
                create+=(--generate-password='letters,digits,32')
            fi
            "${create[@]}" >/dev/null
        fi

        # Current item with the wanted fields set: existing fields (same label) are updated, the
        # others are added. The rest of the item (generated password...) is kept as is.
        current="$(op item get "$title" --vault "$vault" --format json --reveal </dev/null)"
        result="$(printf '%s\n%s' "$current" "$wanted" | jq --slurp --compact-output '
            .[0] as $item
            | ([.[1].fields // {} | to_entries[] | .type = "STRING"]
                + [.[1].secrets // {} | to_entries[] | .type = "CONCEALED"]) as $updates
            | {
                changed: any($updates[]; . as $u | [$item.fields[]? | select(.label == $u.key) | .value] != [$u.value]),
                item: ($item | .fields = reduce $updates[] as $u (.fields // [];
                    if any(.[]; .label == $u.key)
                    then map(if .label == $u.key then .value = $u.value | .type = $u.type else . end)
                    else . + [{label: $u.key, type: $u.type, value: $u.value}]
                    end))
            }')"
        if [[ "$(printf '%s' "$result" | jq '.changed')" == false ]]; then
            {{ just }} log info "Up to date" vault "$vault" item "$title"
            continue
        fi

        {{ just }} log info "Updating the item (1Password approval)" vault "$vault" item "$title"
        id="$(printf '%s' "$current" | jq --raw-output '.id')"
        if ! printf '%s' "$result" | jq '.item' | host-spawn op item edit "$id" --vault "$vault" >/dev/null; then
            {{ just }} log error "Update failed" vault "$vault" item "$title"
            if gum confirm "Print the values, to update the item by hand?"; then
                printf '%s' "$wanted" | jq '.fields + .secrets'
            fi
            exit 1
        fi
    done
