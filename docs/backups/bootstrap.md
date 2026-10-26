# Backups: first deployment

Deploying the backups on a new cluster, with empty repositories, and the tests to run before real applications rely on them. Architecture: [README.md](README.md). Rebuilding a cluster whose backups already exist is a [full rebuild](runbook.md#full-rebuild) instead: the resources below exist already.

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kube-cluster01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| All | B2 account behind a strong password and a second factor. The master key is only used for the setups and never stored. | B2 web interface | Done |
| All | OpenTofu: bucket of the states, admin key of the `backblaze` stack, items `tofu-state-encryption`, `backblaze-b2-tofu-state` and `backblaze-b2-tofu-admin` (`infrastructure` vault). | [tofu/README.md](../../tofu/README.md#setup) | Done |
| 1, 2 | Cluster: Piraeus (`linstor` VolumeSnapshotClass, `replicated-temporary` StorageClass), snapshot-controller, External Secrets with the `onepassword` ClusterSecretStore. | [first-bootstrap.md](../first-bootstrap.md) | Done |
| 1, 2 | Bucket `kube-cluster01-volsync-gz8j9y` (lifecycle rule of 30 days from hiding to deleting), its restricted key, item `restic-volsync` (`kubernetes` vault: generated `password`, `repository`, `access-key-id`, `secret-access-key`). | Entry `kube-cluster01-volsync` in `restic_repositories` (`tofu/backblaze/main.tf`), `just tofu apply backblaze`, then `just tofu plan backblaze` shows no change. | Done |
| 1 | healthchecks.io check `kube-cluster01-volsync`, period 1 day, grace 2 hours. | healthchecks.io | Done |
| 1 | Item `healthchecks` (`kubernetes` vault), field `kube-cluster01-volsync`: the ping URL of the check. Without it, `volsync-monitor` is not ready. | 1Password | Done |
| 3 | Bucket of the NAS, its restricted key, item `restic-nas` in the **`infrastructure`** vault (never synced to the cluster), same fields as `restic-volsync`. | Entry in `restic_repositories` with the `infrastructure` vault, `just tofu apply backblaze`. | To do |
| 3 | healthchecks.io checks `documents`, `groupware` and `media`, period 1 day, grace 2 hours. | healthchecks.io | To do |
| 4 | Bucket and restricted key of CloudNativePG, item `cnpg-b2` (`kubernetes` vault). | `tofu/backblaze`, to define with CNPG. | Later |

## 1. Deploy VolSync and the monitoring

`kubernetes/apps/backups` deploys both.

- [x] **Deployment.** Push, then:

  ```sh
  flux -n backups get ks                                  # volsync and volsync-monitor Ready
  kubectl get storageclass replicated-temporary
  ```

  Expected: both Kustomizations `Ready`, the StorageClass present with `reclaimPolicy: Delete`. `volsync-monitor` stays not ready without the `healthchecks` item ([prerequisites](#prerequisites)).

- [x] **Monitoring job**, run once without waiting for 09:00:

  ```sh
  kubectl -n backups create job --from=cronjob/volsync-monitor volsync-monitor-manual
  kubectl -n backups wait job/volsync-monitor-manual --for=condition=complete --timeout=5m
  kubectl -n backups logs job/volsync-monitor-manual
  kubectl -n backups delete job volsync-monitor-manual
  ```

  Expected: the job completes, its log says `All 0 sources backed up within the last 26 hours` (no application backed up yet), and the healthchecks dashboard shows the ping of the check `kube-cluster01-volsync`.

## 2. Test VolSync

### Test application

A throwaway application checks the component, the recipes and the LINSTOR behaviours. `volsync-test` is a busybox appending the date to `/data/heartbeat.log` every minute, backed up every 15 minutes: the gaps in that file show which backup each restore brought back. It is not kept in the repository: add it for the tests, [remove it](#removing-the-test-application) afterwards.

Flux applies every directory of `kubernetes/apps`. `kubernetes/apps/volsync-test/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: volsync-test
resources:
  - ./namespace.yaml
  - ./volsync-test/ks.yaml
```

`kubernetes/apps/volsync-test/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: volsync-test
  annotations:
    # Never delete a namespace (and everything in it) because of a refactoring.
    kustomize.toolkit.fluxcd.io/prune: disabled
```

`kubernetes/apps/volsync-test/volsync-test/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: volsync-test
spec:
  components:
    - ../../../../components/volsync # relative to spec.path
  dependsOn:
    - name: volsync
      namespace: backups
    - name: external-secrets-stores
      namespace: external-secrets
  interval: 1h
  path: ./kubernetes/apps/volsync-test/volsync-test/app
  postBuild:
    substitute:
      APP: volsync-test
      VOLSYNC_CAPACITY: 1Gi
      VOLSYNC_UID: "1000"
      VOLSYNC_GID: "1000"
      # Every 15 minutes during the test. Must not start with `*`.
      VOLSYNC_SCHEDULE: "0,15,30,45 * * * *"
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: volsync-test
  wait: true
```

`kubernetes/apps/volsync-test/volsync-test/app/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./deployment.yaml
```

`kubernetes/apps/volsync-test/volsync-test/app/deployment.yaml` (no dollar sign in it: Flux substitutes the variables of every manifest of the Kustomization):

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: volsync-test
spec:
  replicas: 1
  strategy:
    type: Recreate # ReadWriteOnce volume
  selector:
    matchLabels:
      app.kubernetes.io/name: volsync-test
  template:
    metadata:
      labels:
        app.kubernetes.io/name: volsync-test
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: heartbeat
          image: docker.io/library/busybox:1.37.0
          command:
            - sh
            - -c
            - while true; do date -u +%FT%TZ >> /data/heartbeat.log; sleep 60; done
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: volsync-test # created by the volsync component
```

### Tests

- [x] **First deployment, empty repository.** Push, then:

  ```sh
  flux -n volsync-test get ks volsync-test                # Ready
  kubectl -n volsync-test get externalsecret,pvc,pod,replicationdestination,replicationsource
  kubectl -n volsync-test get replicationdestination volsync-test-dst -o jsonpath='{.status.latestImage.name}{"\n"}'
  kubectl -n volsync-test exec deploy/volsync-test -- cat /data/heartbeat.log
  ```

  Expected: the ExternalSecret `SecretSynced`, the ReplicationDestination synced once with a `latestImage` (restore of an empty repository), the PVC `Bound` (filled by the populator), the pod running and the log starting at its first minute.

- [x] **Backup**, and what it leaves behind:

  ```sh
  just kube volsync-backup volsync-test
  just kube volsync-snapshots volsync-test
  kubectl -n volsync-test get pvc,volumesnapshot
  kubectl linstor resource-definition list
  kubectl linstor snapshot list
  ```

  Expected once the backup is done:

  - one restic snapshot per backup (host `volsync`, path `/data`), the scheduled ones every 15 minutes besides the manual one;
  - in the namespace, the PVC `volsync-test`, the restic cache `volsync-src-volsync-test-cache`, and a single VolumeSnapshot, the `latestImage` of the ReplicationDestination. No snapshot nor temporary volume of the ReplicationSource left: the clone into `replicated-temporary` is deleted after the sync;
  - in LINSTOR, the resource definitions of these two PVCs, plus the one of the deleted temporary volume of the ReplicationDestination, kept by its snapshot (the only one of `snapshot list`).

- [x] **In-place restore** with the [recipe](runbook.md#one-application-volume-in-place):

  ```sh
  kubectl -n volsync-test exec deploy/volsync-test -- tail -n 3 /data/heartbeat.log
  just kube volsync-restore volsync-test                  # pick a backup a few lines back, answer no to the backup first
  kubectl -n volsync-test exec deploy/volsync-test -- tail -n 20 /data/heartbeat.log
  flux -n volsync-test get ks volsync-test                # resumed, Ready
  kubectl -n volsync-test get deploy,replicationsource,replicationdestination
  ```

  Expected: the log ends with the minute of the picked backup, then a gap until the restart; the lines written after that backup are gone. The Deployment is back to 1 replica, the ReplicationSource is not paused (`NEXT SYNC` set), and `volsync-test-restore` is gone.

- [x] **Restore from scratch** by the populator. Note the last lines of the log first:

  ```sh
  kubectl -n volsync-test exec deploy/volsync-test -- tail -n 3 /data/heartbeat.log
  ```

  Then run the [from scratch procedure](runbook.md#one-application-volume-from-scratch) with `APP=volsync-test NS=volsync-test`, with the backup first and without the HelmRelease lines. Checks:

  ```sh
  kubectl -n volsync-test get replicationdestination volsync-test-dst -o jsonpath='{.status.lastSyncTime}{"\n"}{.status.latestImage.name}{"\n"}'
  kubectl -n volsync-test get pvc,pod,volumesnapshot
  kubectl -n volsync-test exec deploy/volsync-test -- tail -n 20 /data/heartbeat.log
  kubectl linstor snapshot list
  ```

  Expected: a new `lastSyncTime` and `latestImage`; the log goes up to the backup taken first, then a gap, then the new lines. In LINSTOR, the previous snapshot of the ReplicationDestination and the resource definition it kept are gone, replaced by the new ones. The old PV is `Released`: clean it up as the procedure says.

- [x] **Past date**, with a date between two backups:

  ```sh
  B2_VERSION_AT=2026-10-25T20:00:00Z just kube volsync-snapshots volsync-test   # RFC 3339, UTC
  ```

  Expected: the list stops at that date.

- [ ] **Node down** (with three nodes): the backups while a node holding a replica is down. Add the test application again if it was removed already. With the node stopped:

  ```sh
  kubectl linstor resource list                           # the volumes with a replica on the stopped node
  just kube volsync-backup volsync-test
  kubectl -n volsync-test get replicationsource volsync-test
  ```

  Expected, to confirm: LINSTOR may refuse to snapshot a resource with a missing replica. The backups of these volumes are then late, which the monitoring must report.

### Removing the test application

- [x] **Removal from Git.** Remove `kubernetes/apps/volsync-test/`, commit and push, then:

  ```sh
  flux get ks -A | grep volsync-test                      # nothing
  kubectl -n volsync-test get all,pvc,volumesnapshot,replicationsource,replicationdestination,externalsecret
  ```

  Expected: Flux deleted the Kustomization `volsync-test` and pruned its objects (Deployment, PVC, ReplicationSource, ReplicationDestination and its snapshot, ExternalSecret). Only the namespace is left (`prune: disabled`).

- [x] **Cluster cleanup**, as for [any application](runbook.md#removing-an-application):

  ```sh
  kubectl delete namespace volsync-test
  kubectl get pv | grep volsync-test/                      # Released PVs of the test
  kubectl delete pv <name>
  kubectl linstor resource-definition delete <name>
  kubectl linstor resource-definition list
  kubectl linstor snapshot list
  ```

  Expected: the two LINSTOR lists show nothing of the test anymore.

- [x] **Repository**: delete the `volsync-test/` folder in the B2 web interface (*Browse Files*), or leave it: it is small. The restricted key can only hide files.

## 3. NAS data: Backrest

On the NAS:

- [ ] Install the Backrest App. Mount the datasets **read-only**: documents (Nextcloud, Immich), groupware (mail, contacts, calendar), and `media/library/{audiodrama,audiobooks,books,comics}`. Keep the Backrest configuration and cache on a dataset of the App.
- [ ] Web UI: reachable from the LAN only, with authentication.
- [ ] One repository (`restic-nas`), one plan per data set (`documents`, `groupware`, `media`):
  - Schedule: daily, at night, not at the same time as the ZFS snapshots and scrubs.
  - Retention: by time period, daily 28, weekly 8, monthly 6.
  - Prune: weekly. Check: monthly (`--read-data-subset` to limit the download). Backrest runs `forget` and `prune` as separate operations, both work with the restricted key.
  - Exclusions (`documents`): `encoded-video`, `thumbs`, `files_external`, `appdata_*/preview`, `*/cache`, `*/files_trashbin`, `*/files_versions`, `*/uploads`, `*.log`, `*.log.[0-9]`, and `--exclude-if-present .nobackup` (all plans) as an extra backup flag. Anchor the patterns to the paths of the mounts, as the previous autorestic configuration did, to avoid excluding a directory of the same name elsewhere.
  - Hooks: ping the check of the plan at the start, on success and on error.
- [ ] A first backup of each plan, then a test restore of a few files to a scratch dataset.
- [ ] Back up the Backrest configuration (`config.json`) in 1Password (`restic-nas` item, as a file).
- [ ] Once the new backups are trusted: stop autorestic on `home` and delete the old B2 buckets and keys.

## 4. PostgreSQL: CloudNativePG

To write with CloudNativePG (Barman Cloud plugin, [options](evaluations.md#postgresql-options)), starting with a check of the B2 compatibility of Barman (checksums, deletions with the restricted key).
