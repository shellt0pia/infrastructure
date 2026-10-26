# Backups: runbook

Day-to-day administration of the backups. Architecture: [README.md](README.md).

## Recipes

The credentials of each repository are in its `restic-*` 1Password item. The recipes of `kubernetes/mod.just` read them with the workstation service account ([1password-local-access.md](../1password-local-access.md)): listing and reading the backups needs 1Password and B2 only, not the cluster.

| Recipe | What it does |
| --- | --- |
| `just kube volsync-snapshots <app>` | Lists the backups of an application (`restic snapshots --no-lock`). |
| `just kube volsync-restic <app> <restic arguments>` | Any restic command on the repository of an application. |
| `just kube volsync-backup <app>` | Backs the volume up now (manual trigger of the ReplicationSource, removed afterwards: as long as it is set, the schedule is ignored). |
| `just kube volsync-restore <app> [<id> \| latest]` | Restores a backup over the volume, [in place](#one-application-volume-in-place). |

Add `--no-lock` to the read-only restic commands (`snapshots`, `ls`, `diff`, `restore`...): no lock file written (then hidden) in the bucket, no wait on a running mover. With `B2_VERSION_AT=<RFC 3339 date>` in front of them, the restic recipes read the bucket as it was at that date ([recovery after a deletion](#recovery-after-a-deletion-of-the-backups)).

- **Without the recipes**, with the fields of the item:

  ```sh
  export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... RESTIC_REPOSITORY=... RESTIC_PASSWORD=...
  restic snapshots --no-lock
  ```

  For a VolSync repository, `RESTIC_REPOSITORY` is the `repository` field followed by `/<app>`.

- **LINSTOR objects** (volumes, snapshots left behind):

  ```sh
  kubectl linstor resource-definition list
  kubectl linstor snapshot list
  ```

## Backing up an application

1. **Add the component** to the Flux Kustomization (`ks.yaml`) of the application:

   ```yaml
   spec:
     components:
       - ../../../../components/volsync     # relative to spec.path
     dependsOn:
       - name: volsync
         namespace: backups
       - name: external-secrets-stores
         namespace: external-secrets
     postBuild:
       substitute:
         APP: radarr
         VOLSYNC_CAPACITY: 5Gi
         VOLSYNC_UID: "1000"
         VOLSYNC_GID: "1000"
   ```

   - The application mounts the PVC `radarr` and must not define it.
   - `VOLSYNC_UID` and `VOLSYNC_GID`: owner of the files of the volume, the restic mover runs as them.
   - Optional: `VOLSYNC_SCHEDULE` (cron, UTC, `30 1 * * *` by default), `VOLSYNC_STORAGECLASS` (`replicated` by default).
   - `VOLSYNC_SCHEDULE` must not start with `*` (`0,15,30,45 * * * *` rather than `*/15 * * * *`): kustomize drops the quotes around the variable and a leading `*` is then read as a YAML alias by the Flux substitution.
   - The Flux substitution applies to every manifest of the application: a literal `${...}` (in a script, for instance) must be written `$${...}`.
   - Caches outside of the volume (no exclusion patterns), one volume per application ([README.md](README.md#application-volumes-volsync)).
   - `dataSourceRef` is immutable: adding the component to an application that already has its PVC means recreating the PVC (copy the data over, or back it up by other means first).

2. **Deployment.** Push, then:

   ```sh
   APP=radarr NS=media
   flux -n "$NS" get ks "$APP"                            # Ready
   kubectl -n "$NS" get externalsecret,pvc,replicationdestination,replicationsource
   ```

   Expected: the ExternalSecret `<app>-volsync` `SecretSynced`, the ReplicationDestination `<app>-dst` with a `latestImage`, the PVC `Bound`: empty on the first deployment (empty repository), filled from the latest backup on a rebuild.

3. **First backup**, without waiting for the schedule:

   ```sh
   just kube volsync-backup "$APP"
   just kube volsync-snapshots "$APP"
   ```

   Expected: one snapshot, host `volsync`, path `/data`, with the size of the data of the application.

## Removing an application

1. **Removal from Git.** Remove the application (or the component from its `ks.yaml`), commit and push, then:

   ```sh
   APP=radarr NS=media
   kubectl -n "$NS" get pvc,volumesnapshot,replicationsource,replicationdestination,externalsecret
   ```

   Expected: Flux pruned the PVC, the ReplicationSource, the ReplicationDestination (and its snapshot) and the ExternalSecret. The restic cache `volsync-src-<app>-cache` is gone too: delete it otherwise.

2. **Namespace.** A namespace of its own is kept (`prune: disabled`):

   ```sh
   kubectl delete namespace "$NS"
   ```

3. **Volume.** The PV of the application stays `Released` (`reclaimPolicy: Retain`):

   ```sh
   kubectl get pv | grep "$NS/$APP"
   kubectl delete pv <name>
   kubectl linstor resource-definition delete <name>
   ```

   Expected: `kubectl linstor resource-definition list` and `kubectl linstor snapshot list` show nothing of the application anymore.

4. **Repository.** It stays in the bucket (`<app>/` prefix): the restricted key can only hide files. Delete the folder in the B2 web interface (*Browse Files*), or keep it as a last backup.

## Checking the backups

The healthchecks.io check fails when a ReplicationSource is late ([monitoring](README.md#monitoring)). By hand:

- **Last syncs:**

  ```sh
  kubectl get replicationsource -A
  ```

  Expected: `LAST SYNC` within 24 hours and `NEXT SYNC` set for each one (empty: paused).

- **Backups of an application:**

  ```sh
  just kube volsync-snapshots <app>
  ```

  Expected: a backup per day (up to 28), then weekly and monthly ones, with no unexplained jump in the `Size` column.

- **Leftovers:**

  ```sh
  kubectl get volumesnapshot -A
  ```

  Expected: one VolumeSnapshot per backed up application, the `latestImage` of its ReplicationDestination.

- **Monitoring job**, now:

  ```sh
  kubectl -n backups create job --from=cronjob/volsync-monitor volsync-monitor-manual
  kubectl -n backups wait job/volsync-monitor-manual --for=condition=complete --timeout=5m
  kubectl -n backups logs job/volsync-monitor-manual
  kubectl -n backups delete job volsync-monitor-manual
  ```

  Expected: `All <n> sources backed up within the last 26 hours`, and a ping on the healthchecks dashboard. Otherwise the job fails and lists the late ones.

## Refreshing the secrets

The ExternalSecrets of VolSync refresh every 12 hours. After a change of the `restic-volsync` item (key replaced by `just tofu apply backblaze`, [new bucket](#recovery-after-a-deletion-of-the-backups)), force them:

```sh
kubectl get externalsecrets -A --no-headers | awk '$2 ~ /-volsync$/ {print $1, $2}' \
  | while read -r ns name; do kubectl -n "$ns" annotate externalsecret "$name" force-sync="$(date +%s)" --overwrite; done
kubectl get externalsecrets -A | grep -- -volsync
```

Expected: every `-volsync` ExternalSecret `SecretSynced`, with a recent refresh. The next backups use the new values.

## Restores

### One application volume, in place

```sh
just kube volsync-restore radarr                       # lists the backups, newest first, to pick one
just kube volsync-restore radarr 3317bc7b              # or a given backup
just kube volsync-restore radarr latest                # or the latest one
```

The recipe:

1. Finds the namespace (the ReplicationSource is named like the application), the Flux Kustomization that applied it (`kustomize.toolkit.fluxcd.io/*` labels), the Deployments and StatefulSets mounting the PVC and their HelmReleases (`helm.toolkit.fluxcd.io/*` labels). Shows the plan and asks for a confirmation.
2. Suspends the Kustomization and the HelmReleases, scales the workloads to 0 and waits for their pods to be gone.
3. Asks whether to back up the current data first (yes by default), so that the restore can be undone. Side effect: `keep-daily` keeps the last backup of each day, so this backup replaces the scheduled one of the same day in the retention.
4. Pauses the ReplicationSource (no scheduled backup of a half-restored volume), creates the ReplicationDestination `<app>-restore` (manual trigger, `copyMethod: Direct`, `enableFileDeletion`, same repository, cache class and security context as the ReplicationSource) and waits for it, 2 hours at most.
5. Checks the result of the mover and that its logs mention the picked backup, deletes the ReplicationDestination, resumes the ReplicationSource, scales the workloads back to their previous replicas (resuming Flux does not), resumes the HelmReleases then the Kustomization, and waits for the rollouts.

If a step fails after the workloads are stopped, the application stays stopped and the recipe prints the commands left to start it again.

VolSync cannot restore a backup by ID: it restores the latest backup at or before `restoreAsOf` (dates truncated to the second), which the recipe sets to the date of the picked backup. `previous: N` (the N-th backup before that one) also exists.

Manual equivalent:

1. **Stop the application:**

   ```sh
   APP=radarr NS=media
   flux suspend ks "$APP" -n "$NS"                        # the Kustomization of the application
   flux suspend hr "$APP" -n "$NS"                        # if a HelmRelease deploys the workload
   kubectl -n "$NS" get deploy,sts                        # note the replicas
   kubectl -n "$NS" scale deploy/"$APP" --replicas 0
   ```

2. **Restore**, with the date of the backup (`just kube volsync-snapshots "$APP"`, UTC):

   ```sh
   kubectl -n "$NS" patch replicationsource "$APP" --type merge -p '{"spec":{"paused":true}}'
   kubectl create -n "$NS" -f - <<EOF
   apiVersion: volsync.backube/v1alpha1
   kind: ReplicationDestination
   metadata:
     name: $APP-restore
   spec:
     trigger:
       manual: restore
     restic:
       repository: $APP-volsync
       destinationPVC: $APP
       copyMethod: Direct
       enableFileDeletion: true
       restoreAsOf: "2026-10-20T01:30:41Z"   # date of the backup (restic snapshots), UTC
       cacheStorageClassName: replicated-temporary
       cleanupCachePVC: true
       moverSecurityContext:
         runAsUser: 1000          # VOLSYNC_UID / VOLSYNC_GID of the application
         runAsGroup: 1000
         fsGroup: 1000
   EOF
   kubectl -n "$NS" wait replicationdestination/"$APP"-restore --for=jsonpath='{.status.lastManualSync}'=restore --timeout=2h
   kubectl -n "$NS" get replicationdestination "$APP"-restore -o jsonpath='{.status.latestMoverStatus}'
   ```

   Expected: `latestMoverStatus` with `result: Successful`, and its logs mention the picked backup.

3. **Start the application again:**

   ```sh
   kubectl -n "$NS" delete replicationdestination "$APP"-restore
   kubectl -n "$NS" patch replicationsource "$APP" --type merge -p '{"spec":{"paused":null}}'
   kubectl -n "$NS" scale deploy/"$APP" --replicas 1      # the replicas noted above
   flux resume hr "$APP" -n "$NS"
   flux resume ks "$APP" -n "$NS"
   ```

   Expected: the application running with the restored data, `NEXT SYNC` set on the ReplicationSource (`kubectl -n "$NS" get replicationsource "$APP"`).

### One application volume, from scratch

A new PVC filled by the populator, instead of a restore over the existing volume: for a corrupted volume, or to test the rebuild path. The ReplicationDestination `<app>-dst` must be deleted with the PVC: it only restores once, when it is created, and the populator fills every new PVC from the snapshot of that restore. Deleting only the PVC gives back the data of that old restore (an empty volume if it dates from the first deployment). Flux recreates both, the ReplicationDestination restores the latest backup, and the populator waits for it.

The populator always restores the latest backup. For an older one, restore it [in place](#one-application-volume-in-place) afterwards.

1. **Back up the current data** (optional, if they are still worth something):

   ```sh
   APP=radarr NS=media
   just kube volsync-backup "$APP"
   ```

2. **Stop the application:**

   ```sh
   flux suspend ks "$APP" -n "$NS"                        # the Kustomization of the application
   flux suspend hr "$APP" -n "$NS"                        # if a HelmRelease deploys the workload
   kubectl -n "$NS" get deploy,sts                        # note the replicas
   kubectl -n "$NS" scale deploy/"$APP" --replicas 0
   ```

3. **Delete the PVC and the ReplicationDestination:**

   ```sh
   kubectl -n "$NS" get pvc "$APP" -o jsonpath='{.spec.volumeName}{"\n"}'   # the old PV, for the cleanup
   kubectl -n "$NS" delete pvc "$APP"
   kubectl -n "$NS" delete replicationdestination "$APP"-dst
   ```

4. **Start the application again:**

   ```sh
   flux resume hr "$APP" -n "$NS"
   flux resume ks "$APP" -n "$NS"
   kubectl -n "$NS" scale deploy/"$APP" --replicas 1      # if Flux did not
   kubectl -n "$NS" wait pvc/"$APP" --for=jsonpath='{.status.phase}'=Bound --timeout=2h
   kubectl -n "$NS" get replicationdestination "$APP"-dst -o jsonpath='{.status.lastSyncTime}{"\n"}{.status.latestImage.name}{"\n"}'
   ```

   Expected: a new `lastSyncTime` and `latestImage` on the ReplicationDestination, the PVC `Bound`, the application running with the data of the latest backup.

5. **Clean up the old volume**, once the restore is checked. It stays `Released` (`reclaimPolicy: Retain`):

   ```sh
   kubectl delete pv <old PV>
   kubectl linstor resource-definition delete <old PV>
   ```

### A few files

1. **Find the files:**

   ```sh
   just kube volsync-snapshots radarr
   just kube volsync-restic radarr ls latest /data/<path> --no-lock
   ```

2. **Restore them locally:**

   ```sh
   just kube volsync-restic radarr restore <id> --include /data/<path> --target /tmp/restore --no-lock
   ```

   Expected: the files under `/tmp/restore/data/<path>`.

3. **Copy them into the pod** (needs `tar` in the container):

   ```sh
   kubectl -n media cp /tmp/restore/data/<path> <pod>:/data/<path>
   ```

For the NAS data, the Backrest UI does the same (restore to a scratch dataset, or download).

## Disaster recovery

### etcd quorum lost

There is no etcd backup ([why](evaluations.md#etcd-not-backed-up)). One node lost out of three: etcd keeps its quorum, rebuild the node ([first-bootstrap.md](../first-bootstrap.md#appendix--rebuilding-a-node)). Without a surviving control plane disk: [full rebuild](#full-rebuild).

Quorum lost (including during the 2-node phase) with the disk of at least one control plane node intact, see the [Talos disaster recovery guide](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery):

1. **Copy the database** out of a surviving node first: wiping `EPHEMERAL` deletes it.

   ```sh
   talosctl -n kube-01.shelltopia.net cp /var/lib/etcd/member/snap/db .
   ```

2. **Prepare the nodes**: every control plane node in the `Preparing` state (`EPHEMERAL` wiped if needed).

3. **Bootstrap from the copy:**

   ```sh
   talosctl -n kube-01.shelltopia.net bootstrap --recover-from=./db --recover-skip-hash-check
   talosctl -n kube-01.shelltopia.net etcd members
   kubectl get nodes
   ```

   Expected: every control plane node listed as an etcd member, the nodes `Ready`.

### Full rebuild

Target: one day.

1. **Cluster**: [first-bootstrap.md](../first-bootstrap.md) from phase 8 (the 1Password items and the B2 buckets already exist): bootstrap, Flux, External Secrets.

2. **Application volumes**: Flux deploys VolSync before the applications (`dependsOn`), the PVCs are created and filled from the latest backups, the applications start with their data.

   ```sh
   kubectl get replicationdestination -A
   kubectl get pvc -A
   ```

   Expected: every ReplicationDestination with a `latestImage` (last sync set), every PVC `Bound`.

3. **CloudNativePG clusters**: recovery from the object store (to write with CNPG).

4. **NAS data**: not affected (backed up by the NAS itself). If the NAS is lost too: restore the Backrest configuration from 1Password on the new NAS, then each plan.

5. **etcd**: not restored, the cluster is new. Let's Encrypt limits duplicate certificates to 5 per week: try with `letsencrypt-staging` first if a rebuild is repeated.

### Recovery after a deletion of the backups

With the restricted keys, a `forget`, a `prune` or any deletion through the S3 API only hides files: B2 keeps every version until the lifecycle rule deletes the hidden ones, 30 days after they were hidden. Restic only sees the visible files, so the deleted snapshots are missing from `restic snapshots`. Reading the bucket as it was at a date T0 brings them back: the b2 backend of rclone can do it (`version_at` option), and restic can use rclone as its backend. This view is read-only, so every restic command needs `--no-lock`.

1. **Freeze the bucket** first, with the master key: in the web interface, bucket, *Lifecycle Settings*, *Keep all versions of the file*. The hidden versions are then no longer deleted while investigating. Set the 30-day rule again once done.

2. **Pick T0**, a date before the deletion: the date of the hide markers of the snapshot files, in the web interface (*Browse Files*, *Show hidden files*) or:

   ```sh
   b2 ls --long --versions --recursive b2://<bucket>/<app>/snapshots/
   ```

3. **Read the backups at T0**, with the usual credentials (the restricted key can list the versions):

   ```sh
   B2_VERSION_AT=2026-10-20T00:00:00Z just kube volsync-snapshots radarr
   B2_VERSION_AT=2026-10-20T00:00:00Z just kube volsync-restic radarr restore <id> --target /tmp/restore --no-lock
   ```

   Expected: the deleted snapshots are listed again. Enough to get a few files or one volume back (restore locally, then `kubectl cp`).

   Without the recipes (tested on 2026-10-25); the keyID and the key are the `access-key-id` and `secret-access-key` fields, the S3 credentials of B2 being the application key itself:

   ```sh
   export RCLONE_CONFIG_B2_TYPE=b2 RCLONE_CONFIG_B2_ACCOUNT=<keyID> RCLONE_CONFIG_B2_KEY=<application key>
   export RCLONE_B2_VERSION_AT=2026-10-20T00:00:00Z
   export RESTIC_REPOSITORY=rclone:b2:<bucket>/<app> RESTIC_PASSWORD=...
   restic snapshots --no-lock
   restic restore <id> --target ./restored --no-lock
   ```

4. **Rebuild the bucket at T0**, so that VolSync (or the populator, after a rebuild) sees the backups again. Not tested yet ([open point](evaluations.md#open-points)): try it on a new throwaway bucket first. The copy goes through the workstation (download then upload); the B2 egress is free up to 3 times the stored data per month.

   ```sh
   # Master key: new bucket with the lifecycle rule, a read-only key on the old one, a restricted key on the new one.
   b2 bucket create kube-cluster01-volsync-2-gz8j9y allPrivate \
     --lifecycle-rule '{"daysFromHidingToDeleting": 30, "daysFromUploadingToHiding": null, "fileNamePrefix": ""}'
   b2 key create --bucket kube-cluster01-volsync-gz8j9y recovery-read listBuckets,listFiles,readFiles
   b2 key create --bucket kube-cluster01-volsync-2-gz8j9y restic-volsync-2 listBuckets,listFiles,readFiles,writeFiles

   # The date on the source remote only: a global RCLONE_B2_VERSION_AT would make the destination read-only too.
   export RCLONE_CONFIG_OLD_TYPE=b2 RCLONE_CONFIG_OLD_ACCOUNT=<recovery-read keyID> RCLONE_CONFIG_OLD_KEY=<key>
   export RCLONE_CONFIG_OLD_VERSION_AT=2026-10-20T00:00:00Z
   export RCLONE_CONFIG_NEW_TYPE=b2 RCLONE_CONFIG_NEW_ACCOUNT=<restic-volsync-2 keyID> RCLONE_CONFIG_NEW_KEY=<key>
   rclone copy old:kube-cluster01-volsync-gz8j9y new:kube-cluster01-volsync-2-gz8j9y --fast-list --transfers 16 --progress

   # Each repository of the copy (new key, read-write: check takes a lock).
   RESTIC_REPOSITORY=s3:https://s3.eu-central-003.backblazeb2.com/kube-cluster01-volsync-2-gz8j9y/radarr restic check --read-data-subset 10%
   ```

   Expected: `restic check` finds no error, and `restic snapshots` on the copy lists the backups up to T0.

5. **Point the cluster to the new bucket**: in the 1Password item `restic-volsync`, the fields `repository`, `access-key-id` and `secret-access-key` (personal account: web interface or `host-spawn op item edit`; the password does not change). Then [refresh the secrets](#refreshing-the-secrets).

6. **Delete the old bucket**, once the backups run on the new one, with the master key:

   ```sh
   b2 rm --versions --recursive b2://kube-cluster01-volsync-gz8j9y
   b2 bucket delete kube-cluster01-volsync-gz8j9y
   b2 key list --long                                      # keyIDs of the old key and of recovery-read
   b2 key delete <keyID>
   ```

   Then bring the new bucket under OpenTofu ([tofu/README.md](../../tofu/README.md#bucket-rebuilt-by-hand)).

Same procedure for the NAS bucket (Backrest configuration on the NAS).

### Ransomware or compromised cluster

Assumes that the entry point is found and closed and the attacker evicted. Everything the cluster could read is considered leaked: the B2 keys of the cluster, the `kubernetes` vault (through the External Secrets service account), the Talos PKI. The backups made after the intrusion may contain encrypted data or planted files, even when nothing was deleted.

1. **Freeze the buckets** of the cluster (step 1 [above](#recovery-after-a-deletion-of-the-backups)), and the NAS bucket if the NAS was reached.

2. **Revoke the credentials**: the B2 keys of the cluster, the token of the External Secrets service account and the other tokens of the `kubernetes` vault (Cloudflare...), and the workstation service account if the workstation is suspected (then the OpenTofu admin key and the other secrets of the `infrastructure` vault too). B2 keys, with the master key:

   ```sh
   b2 key list --long
   b2 key delete <keyID>
   ```

3. **Pick T0** before the intrusion: the size jumps in the `Size` column, and the differences between consecutive backups.

   ```sh
   B2_VERSION_AT=<date> just kube volsync-snapshots <app>
   just kube volsync-restic <app> diff <id1> <id2> --no-lock
   ```

4. **Rebuild each bucket at T0** (step 4 [above](#recovery-after-a-deletion-of-the-backups)), even if no snapshot was deleted: the copy contains no backup made after T0, so the populator restores the last clean one. New restricted keys.

5. **New secrets**: update the `restic-*` items, set the new tokens. Talos: new secrets bundle (`just talos gen-secrets` refuses to overwrite: archive the `talos-secrets` item first).

6. **Rebuild the cluster**: wipe the nodes and rebuild from scratch ([first-bootstrap.md](../first-bootstrap.md)). **Do not restore etcd**: it may contain objects of the attacker, and the old PKI.

7. **Applications**: Flux deploys them, the populator fills the volumes from the copies. Check the data of each application.

8. **CloudNativePG**: recovery with `targetTime` set to T0 (to write with CNPG).

9. **NAS**, if it was reached: roll the datasets back to a ZFS snapshot older than T0 first (the snapshots cannot be changed through NFS), Backrest from the NAS bucket read at T0 otherwise.

10. **Clean up**, once everything is checked: delete the old buckets and keys.
