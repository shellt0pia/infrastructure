set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

export KUBECONFIG := justfile_directory() / "kubeconfig"

just := quote(just_executable()) + " --justfile " + quote(justfile())

# Vault of the restic-* items (docs/backups/README.md), read with the workstation service account
# (docs/1password-local-access.md).
op_vault := "kubernetes"

# Read-only restic commands (snapshots, ls, diff, restore...) should get `--no-lock`: no lock file
# to create (then hide) in the bucket, no wait on a running mover.
[group('backups')]
[doc('List the backups of an application, from 1Password and B2 only (works without the cluster)')]
volsync-snapshots app:
    {{ just }} kube volsync-restic '{{ app }}' snapshots --no-lock

[group('backups')]
[doc('Run restic on the VolSync repository of an application, e.g. `just kube volsync-restic radarr ls latest --no-lock`')]
[positional-arguments]
volsync-restic app *args:
    {{ just }} kube restic restic-volsync "$@"

# The manual trigger replaces the schedule of the ReplicationSource as long as it is set: it is
# always removed afterwards, even on failure or Ctrl+C.
[group('backups')]
[doc('Back up the volume of an application now, e.g. `just kube volsync-backup radarr`')]
volsync-backup app:
    app='{{ app }}'
    ns="$({{ just }} kube volsync-namespace "$app")"
    if [[ "$(kubectl --namespace "$ns" get replicationsource "$app" --output jsonpath='{.spec.paused}')" == true ]]; then
        {{ just }} log fatal "The ReplicationSource is paused" app "$app" namespace "$ns"
    fi
    trigger="backup-$(date +%s)"
    trap 'kubectl --namespace "$ns" patch replicationsource "$app" --type merge --patch "{\"spec\":{\"trigger\":{\"manual\":null}}}" >/dev/null' EXIT
    kubectl --namespace "$ns" patch replicationsource "$app" --type merge --patch "{\"spec\":{\"trigger\":{\"manual\":\"$trigger\"}}}" >/dev/null
    {{ just }} log info "Backing up..." app "$app" namespace "$ns"
    if ! kubectl --namespace "$ns" wait "replicationsource/$app" --for="jsonpath={.status.lastManualSync}=$trigger" --timeout=2h >/dev/null; then
        {{ just }} log fatal "Backup not finished after 2 hours" app "$app" namespace "$ns"
    fi
    status="$(kubectl --namespace "$ns" get replicationsource "$app" --output json)"
    if [[ "$(jq --raw-output '.status.latestMoverStatus.result' <<< "$status")" != Successful ]]; then
        {{ just }} log fatal "Backup failed" app "$app" namespace "$ns" logs "$(jq --raw-output '.status.latestMoverStatus.logs' <<< "$status")"
    fi
    {{ just }} log info "Backup done" app "$app" namespace "$ns"

# In-place restore of the volume of an application (the PVC named like the application, see
# kubernetes/components/volsync):
# 1. Pick the backup: argument (ID prefix or `latest`) or list. VolSync cannot target an ID: it
#    restores the latest backup at or before `restoreAsOf`, set to the date of the picked one.
# 2. Suspend the Flux Kustomization of the ReplicationSource and the HelmReleases of the workloads
#    mounting the volume, scale these workloads to 0, wait for their pods to be gone.
# 3. Optionally back up the current data (volsync-backup), then pause the ReplicationSource.
# 4. Manual ReplicationDestination `<app>-restore`, copyMethod Direct (straight into the PVC), the
#    files absent from the backup are deleted.
# 5. Delete it, resume the ReplicationSource, scale back to the previous replicas (resuming Flux
#    does not do it), resume Flux.
# If anything fails after step 2, the application is left stopped and the commands to start it
# again are printed.
[group('backups')]
[doc('Restore a backup over the volume of an application, e.g. `just kube volsync-restore radarr` (pick in a list), `... radarr 3317bc7b` or `... radarr latest`')]
volsync-restore app snapshot='':
    # VolSync only sees the visible files of the bucket: list the same backups as it does.
    unset B2_VERSION_AT
    app='{{ app }}'
    ns="$({{ just }} kube volsync-namespace "$app")"
    source="$(kubectl --namespace "$ns" get replicationsource "$app" --output json)"

    snapshots="$({{ just }} kube volsync-restic "$app" snapshots --json --no-lock)"
    if [[ "$(jq length <<< "$snapshots")" == 0 ]]; then
        {{ just }} log fatal "No backup in the repository" app "$app"
    fi
    id='{{ snapshot }}'
    if [[ -z "$id" ]]; then
        choice="$(jq --raw-output 'sort_by(.time) | reverse | .[] | [.short_id, .time, (.summary.total_bytes_processed // 0 | tostring)] | @tsv' <<< "$snapshots" \
            | while IFS=$'\t' read -r short_id time bytes; do
                printf '%s  %s  %s\n' "$short_id" "$(date --date "$time" '+%F %T %Z')" "$(numfmt --to iec-i --suffix B "$bytes")"
            done \
            | gum choose --header "Backup of $app to restore (newest first)")"
        id="${choice%% *}"
    elif [[ "$id" == latest ]]; then
        id="$(jq --raw-output 'max_by(.time).id' <<< "$snapshots")"
    fi
    snapshot="$(jq --compact-output --arg id "$id" 'map(select(.id | startswith($id)))' <<< "$snapshots")"
    if [[ "$(jq length <<< "$snapshot")" != 1 ]]; then
        {{ just }} log fatal "Unknown or ambiguous backup ID" app "$app" snapshot "$id"
    fi
    short_id="$(jq --raw-output '.[0].short_id' <<< "$snapshot")"
    time="$(jq --raw-output '.[0].time' <<< "$snapshot")"
    # The mover compares dates truncated to the second.
    as_of="$(date --utc --date "$time" '+%Y-%m-%dT%H:%M:%SZ')"

    ks="$(jq --raw-output '.metadata.labels["kustomize.toolkit.fluxcd.io/name"] // ""' <<< "$source")"
    ks_ns="$(jq --raw-output '.metadata.labels["kustomize.toolkit.fluxcd.io/namespace"] // ""' <<< "$source")"
    workloads="$(kubectl --namespace "$ns" get deployments,statefulsets --output json | jq --compact-output --arg pvc "$app" '
        [.items[]
         | select(any(.spec.template.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))
         | {
             ref: "\(.kind | ascii_downcase)/\(.metadata.name)",
             replicas: .spec.replicas,
             helmrelease: (.metadata.labels["helm.toolkit.fluxcd.io/name"] // ""),
             helmrelease_ns: (.metadata.labels["helm.toolkit.fluxcd.io/namespace"] // "")
           }]')"
    mapfile -t refs < <(jq --raw-output '.[] | "\(.ref) \(.replicas)"' <<< "$workloads")
    mapfile -t helmreleases < <(jq --raw-output '.[] | select(.helmrelease != "") | "\(.helmrelease) \(.helmrelease_ns)"' <<< "$workloads" | sort --unique)

    {{ just }} log info "Restore plan" app "$app" namespace "$ns" backup "$short_id" date "$(date --date "$time" '+%F %T %Z')" \
        kustomization "${ks:-none}" helmreleases "${helmreleases[*]:-none}" workloads "${refs[*]:-none}"
    if [[ ${#refs[@]} == 0 ]]; then
        {{ just }} log warn "No Deployment or StatefulSet mounts the volume" app "$app" namespace "$ns"
    fi
    if ! gum confirm --default=false "Restore $short_id over the volume $ns/$app? The workloads are stopped, the files absent from the backup are deleted."; then
        {{ just }} log warn "Restore cancelled" app "$app"
        exit 1
    fi
    backup=false
    if gum confirm --default=true "Back up the current data before the restore (once the workloads are stopped)?"; then
        backup=true
    fi

    # Commands starting the application again, in order. Each one is removed once run: on failure,
    # the remaining ones are printed.
    resume=()
    on_exit() {
        if (( ${#resume[@]} )); then
            {{ just }} log error "The restore did not complete, the application is left stopped. Once the problem is understood, start it again with:" app "$app" namespace "$ns"
            printf '  %s\n' "${resume[@]}" >&2
        fi
    }
    trap on_exit EXIT

    if [[ -n "$ks" ]]; then
        flux suspend kustomization "$ks" --namespace "$ks_ns"
        resume=("flux resume kustomization $ks --namespace $ks_ns" "${resume[@]}")
    else
        {{ just }} log warn "The ReplicationSource is not managed by a Flux Kustomization" app "$app" namespace "$ns"
    fi
    for helmrelease in "${helmreleases[@]}"; do
        read -r name hr_ns <<< "$helmrelease"
        flux suspend helmrelease "$name" --namespace "$hr_ns"
        resume=("flux resume helmrelease $name --namespace $hr_ns" "${resume[@]}")
    done
    for ref in "${refs[@]}"; do
        read -r workload replicas <<< "$ref"
        kubectl --namespace "$ns" scale "$workload" --replicas 0
        resume=("kubectl --namespace $ns scale $workload --replicas $replicas" "${resume[@]}")
    done

    deadline=$((SECONDS + 600))
    while true; do
        pods="$(kubectl --namespace "$ns" get pods --output json | jq --raw-output --arg pvc "$app" '
            [.items[]
             | select(.status.phase != "Succeeded" and .status.phase != "Failed")
             | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))
             | .metadata.name]
            | join(" ")')"
        [[ -n "$pods" ]] || break
        if (( SECONDS > deadline )); then
            {{ just }} log fatal "Pods still using the volume after 10 minutes" app "$app" namespace "$ns" pods "$pods"
        fi
        {{ just }} log info "Waiting for the pods using the volume to stop..." app "$app" pods "$pods"
        sleep 5
    done

    if [[ "$backup" == true ]]; then
        {{ just }} kube volsync-backup "$app"
    fi
    kubectl --namespace "$ns" patch replicationsource "$app" --type merge --patch '{"spec":{"paused":true}}' >/dev/null
    resume=("kubectl --namespace $ns patch replicationsource $app --type merge --patch '{\"spec\":{\"paused\":null}}'" "${resume[@]}")

    trigger="restore-$(date +%s)"
    kubectl --namespace "$ns" delete replicationdestination "$app-restore" --ignore-not-found >/dev/null
    jq --arg as_of "$as_of" --arg trigger "$trigger" '
        {
          apiVersion: "volsync.backube/v1alpha1",
          kind: "ReplicationDestination",
          metadata: {name: "\(.metadata.name)-restore", namespace: .metadata.namespace},
          spec: {
            trigger: {manual: $trigger},
            restic: {
              repository: .spec.restic.repository,
              destinationPVC: .spec.sourcePVC,
              copyMethod: "Direct",
              enableFileDeletion: true,
              restoreAsOf: $as_of,
              cacheStorageClassName: .spec.restic.cacheStorageClassName,
              cleanupCachePVC: true,
              moverSecurityContext: .spec.restic.moverSecurityContext
            }
          }
        } | del(.. | nulls)' <<< "$source" | kubectl create --filename - >/dev/null
    # Must be gone before the workloads start: a retried mover would write into the volume.
    resume=("kubectl --namespace $ns delete replicationdestination $app-restore" "${resume[@]}")
    {{ just }} log info "Restoring..." app "$app" namespace "$ns" backup "$short_id" restore_as_of "$as_of"
    if ! kubectl --namespace "$ns" wait "replicationdestination/$app-restore" --for="jsonpath={.status.lastManualSync}=$trigger" --timeout=2h >/dev/null; then
        {{ just }} log fatal "Restore not finished after 2 hours, see the ReplicationDestination and its mover pod" app "$app" namespace "$ns"
    fi
    status="$(kubectl --namespace "$ns" get replicationdestination "$app-restore" --output json)"
    result="$(jq --raw-output '.status.latestMoverStatus.result' <<< "$status")"
    logs="$(jq --raw-output '.status.latestMoverStatus.logs' <<< "$status")"
    if [[ "$result" != Successful || "$logs" == *"No eligible"* ]]; then
        {{ just }} log fatal "Restore failed" app "$app" namespace "$ns" result "$result" logs "$logs"
    fi
    if [[ "$logs" != *"$short_id"* ]]; then
        {{ just }} log warn "The mover logs do not mention the picked backup, check which one was restored" app "$app" backup "$short_id" logs "$logs"
    fi
    {{ just }} log info "Restore done, starting the application again" app "$app" namespace "$ns" backup "$short_id"

    while (( ${#resume[@]} )); do
        eval "${resume[0]}"
        resume=("${resume[@]:1}")
    done
    for ref in "${refs[@]}"; do
        read -r workload _ <<< "$ref"
        if ! kubectl --namespace "$ns" rollout status "$workload" --timeout 10m; then
            {{ just }} log warn "Not ready after 10 minutes" app "$app" namespace "$ns" workload "$workload"
        fi
    done

# Namespace of an application: the one of its ReplicationSource (named like the application).
[private]
volsync-namespace app:
    mapfile -t namespaces < <(kubectl get replicationsources.volsync.backube --all-namespaces --field-selector 'metadata.name={{ app }}' --output jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}')
    if (( ${#namespaces[@]} != 1 )); then
        {{ just }} log fatal "Expected one ReplicationSource with this name" app '{{ app }}' found "${#namespaces[@]}"
    fi
    echo "${namespaces[0]}"

# restic with the credentials of a restic-* item of 1Password, on its repository or on a sub-path
# of it (VolSync: one repository per application). With B2_VERSION_AT set to an RFC 3339 date, the
# bucket is read through rclone as it was at that date, hidden versions included: read-only, so
# `--no-lock` is mandatory (docs/backups/runbook.md#recovery-after-a-deletion-of-the-backups).
[private]
[positional-arguments]
restic item path *args:
    repository="$(op read "op://{{ op_vault }}/$1/repository")"
    AWS_ACCESS_KEY_ID="$(op read "op://{{ op_vault }}/$1/access-key-id")"
    AWS_SECRET_ACCESS_KEY="$(op read "op://{{ op_vault }}/$1/secret-access-key")"
    RESTIC_PASSWORD="$(op read "op://{{ op_vault }}/$1/password")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
    if [[ -n "${B2_VERSION_AT:-}" ]]; then
        # The B2 application key is also the S3 key pair. The repository is s3:https://<endpoint>/<bucket>.
        RCLONE_CONFIG_B2_TYPE=b2
        RCLONE_CONFIG_B2_ACCOUNT="$AWS_ACCESS_KEY_ID"
        RCLONE_CONFIG_B2_KEY="$AWS_SECRET_ACCESS_KEY"
        RCLONE_B2_VERSION_AT="$B2_VERSION_AT"
        export RCLONE_CONFIG_B2_TYPE RCLONE_CONFIG_B2_ACCOUNT RCLONE_CONFIG_B2_KEY RCLONE_B2_VERSION_AT
        repository="rclone:b2:${repository##*/}"
    fi
    export RESTIC_REPOSITORY="$repository${2:+/$2}"
    restic "${@:3}"
