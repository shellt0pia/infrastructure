# Backups: evaluations and open points

What was tested, considered or rejected, and what is still pending. The resulting architecture is in [README.md](README.md).

## Restricted B2 key test

Done on 2026-10-25 on a throwaway bucket, with the [B2 CLI](https://www.backblaze.com/docs/cloud-storage-command-line-tools) v4 (`b2`, installed by mise) and `restic` on the workstation. To redo if B2 changes its key capabilities.

1. **Bucket and restricted key**, with the master key (lifecycle rule of 7 days for the test):

   ```sh
   b2 bucket create shelltopia-restic-test allPrivate \
     --lifecycle-rule '{"daysFromHidingToDeleting": 7, "daysFromUploadingToHiding": null, "fileNamePrefix": ""}'
   b2 key create --bucket shelltopia-restic-test restic-test listBuckets,listFiles,readFiles,writeFiles
   ```

2. **Restic with the restricted key** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), `RESTIC_REPOSITORY=s3:https://s3.eu-central-003.backblazeb2.com/shelltopia-restic-test`, any `RESTIC_PASSWORD`:

   ```sh
   restic init
   restic backup ~/some-directory           # three times, changing or deleting files between them
   restic forget --keep-last 1 --prune
   restic unlock
   restic check --read-data
   ```

   Result: every restic command succeeded.

3. **Versions in the bucket**, with the master key:

   ```sh
   b2 ls --versions --recursive b2://shelltopia-restic-test
   ```

   Result: two versions (the file and its hide marker) of every removed lock, snapshot, index and pack.

4. **Deletion with the restricted key**, `b2` authorized with it:

   ```sh
   b2 rm --versions --recursive b2://shelltopia-restic-test
   ```

   Result: refused for every file (`unauthorized`).

5. **Recovery**: read the bucket as it was before the prune, through the rclone backend of restic (commands in [recovery after a deletion of the backups](runbook.md#recovery-after-a-deletion-of-the-backups), step 3).

   Result: the removed snapshots were listed and restored again.

6. **Cleanup**: the bucket `shelltopia-restic-test` and the key `restic-test` were deleted.

## etcd: not backed up

etcd is deliberately not backed up. A daily `talosctl etcd snapshot` to B2 was considered and dropped:

- **Everything it holds can be rebuilt.** The manifests are in Git and applied by Flux, the secrets are in 1Password (External Secrets), the Talos secrets bundle is in 1Password, and the application data is covered by the volume, PostgreSQL and NAS backups. The [full rebuild](runbook.md#full-rebuild) meets the one-day objective without etcd. What only lives in the cluster is generated again: cert-manager issues the certificates again.
- **A snapshot is useful in a narrow case only.** It brings back the cluster objects as of the snapshot, including the PVs and the LINSTOR objects (Piraeus keeps its state in the Kubernetes API), which only makes sense on nodes that still hold the matching volumes. After a rebuild on new disks, it would bring back PVs pointing to volumes that no longer exist.
- **The failures it would cover are handled otherwise:**
  - One node lost out of three: etcd keeps its quorum, the replacement node joins again ([first-bootstrap.md](../first-bootstrap.md#appendix--rebuilding-a-node)).
  - Quorum lost, including during the 2-node phase until `home` becomes kube-02, with the disk of at least one control plane node intact: the database is copied from that disk ([etcd quorum lost](runbook.md#etcd-quorum-lost)).
  - Everything lost: [full rebuild](runbook.md#full-rebuild).
- **The case left uncovered is accepted:** etcd lost on every node while the NVMe disks (LINSTOR volumes) are intact. The volumes are then restored from their backups (RPO 24 h) instead of being found again with a snapshot. It needs the system disks of all the nodes to fail and not the NVMe ones, which a shared event (power surge, fire, theft) would not do.
- **It has a cost:** Talos API access from pods (`os:etcd:backup` role and the `backups` namespace in `KubeTalosAPIAccessConfig`), a bucket, a key, a CronJob and a check to maintain, and a restore that would rarely be exercised.

To reconsider if the cluster ends up holding state that exists nowhere else (a secret generated in the cluster and absent from 1Password, an operator whose state cannot be rebuilt from Git and the volumes), or if the control plane is reduced to a single node (a snapshot is then much more important, as the Talos guide says).

## PostgreSQL options

Proposed: the **Barman Cloud plugin** (CNPG-I). The in-tree `barmanObjectStore` is deprecated. To decide when CloudNativePG is implemented.

| Option | WAL / PITR | Maturity | Notes |
| --- | --- | --- | --- |
| Barman Cloud plugin | Yes | Official, v0.15.x | `ScheduledBackup`, recovery-window retention, one S3 target (B2). Barman uses boto3: check the B2 checksum compatibility (`AWS_REQUEST_CHECKSUM_CALCULATION=when_required`, `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`). |
| CSI `VolumeSnapshot` backups | No (snapshot only, unless combined with WAL archiving) | Mature | Complement, not a replacement. |
| pgBackRest plugin | Yes | Too young | |
| `pg_dump` CronJob | No | Mature | Optional logical copy. |

Barman writes its own format, not restic: the [restricted-key reasoning](README.md#protection-against-ransomware-and-stolen-keys) has to be checked again for it (Barman deletes old backups and WALs itself).

## Kopiur: evaluated, to revisit

[Kopiur](https://github.com/home-operations/kopiur) (home-operations) is a Kubernetes operator backing up PVCs with Kopia, written in Rust, AGPL. It was seriously considered, alone or in parallel with VolSync, and set aside on 2026-10-25: **VolSync only for now**, kopiur to look at again in a few months (early 2027).

What makes it attractive:

- Kopia: one repository for every application (deduplication across them), faster maintenance, a CLI and a UI able to browse the snapshots.
- Restores by snapshot ID: `kubectl kopiur restore --from-snapshot <id> --to-pvc <app> --enable-file-deletion --wait` (krew plugin), into the PVC, a new PVC (`--create-pvc`) or through its volume populator. One `Snapshot` CR per backup, visible with `kubectl`.
- Object Lock supported (`blobRetention`) on the s3, azure and gcs backends.
- An optional web UI (`kopiur-ui`).

Why not now:

- **Young project**: API `v1alpha1` (breaking changes possible at each release, nine CRDs to follow), mainly one developer, written with the help of LLMs, few users yet.
- **Main risk: losing backups silently.** Backups not running (or failing) without an alert, or snapshots deleted by a bug: each `Snapshot` CR has a finalizer and `deletionPolicy: Delete` by default, and the retention deletes CRs. ADR 0006 describes a real incident of about 650 cascading deletions; guards were added since (`onScheduleDelete: Retain` by default, a namespace deletion policy, `deletionProtection`, a circuit breaker in ADR 0007). With the restricted B2 keys, such deletions would be recoverable for 30 days, if noticed.
- Not simpler to operate here:
  - Object Lock does not work with the native b2 backend (S3 backend needed), kopiur does not extend the locks, and the snapshots deleted under Object Lock are not listed anymore anyway (they come back with `kopia repository connect ... --point-in-time`, like the rclone view of restic). The restricted keys already cover the need.
  - Its `asOf` only picks a snapshot; it does not expose the point-in-time view of the storage.
  - Like VolSync, no automatic Flux suspension nor scale-down before an in-place restore ("scale the app down first"): a recipe is needed either way.
  - A validating webhook (`failurePolicy: Fail`) on its CRs, CRD upgrades to handle outside of Helm (`crds/` is not upgraded), and a UI without authentication of its own (proxy header and Kubernetes impersonation; no identity provider here yet).
- Running both in parallel was considered (VolSync primary and populator, kopiur alongside with its own bucket and an independent monitor reading the Kopia repository): about twice the storage of the volumes and a second system to watch, for an evaluation only.

To check when revisiting:

- [ ] API promoted to `v1beta1` (or CRDs stable over several releases), with an upgrade path documented.
- [ ] More maintainers or users, release cadence, open issues about lost or deleted snapshots.
- [ ] Metrics or alerts for missing and failed snapshots (not only failed jobs).
- [ ] Restore without kopiur documented and tested (plain `kopia` CLI).
- [ ] CRD upgrades handled by the chart.

Adopting it later: run it in parallel first (own bucket `shelltopia-kopiur`, S3 backend, restricted key and lifecycle rule, own password, one Flux Kustomization per application so that a webhook outage does not block the applications, schedule apart from VolSync, small cache, independent monitor, monthly restore test), and drop VolSync only after about 6 months without problem. Switching the populator means recreating each PVC: `dataSourceRef` is immutable.

## Rejected options

| Option | Why not |
| --- | --- |
| etcd snapshots | Everything etcd holds is rebuilt from Git, 1Password and the backups, see [above](#etcd-not-backed-up). |
| Velero | Backs up the cluster resources (useless with Flux), imperative restores fighting Flux, privileged node-agent, no path exclusions either. VolSync is declarative and its populator rebuilds the volumes on its own. |
| Kopia mover of VolSync | Only in an unofficial fork. |
| Kopiur | Too young for now, see [above](#kopiur-evaluated-to-revisit). |
| Backrest UI for the cluster repositories | About 30 repositories (one per application) to add by hand, read-only use not tested. The [recipes](runbook.md#recipes) list, browse (`ls`) and restore them from 1Password and B2. |
| Backrest in the cluster for the NAS data | 160 GiB read through the single NIC of the nodes, and no backups while the cluster is down. |
| Hetzner Storage Box | No S3 (SFTP/Borg/rsync only), 3.20 € ex VAT/month per TB flat: not cheaper for ~250 GB. |
| Cloudflare R2 | About twice the price of B2. |
| rsync.net | 800 GiB minimum, about 12 $/month. |
| BorgBase | 3 $/month for 250 GB, about twice B2. Was the fallback if the restricted B2 key had not worked. |
| TrueNAS TrueCloud Backup | Storj only, $7/TB/month with a $5 minimum. |
| TrueNAS Cloud Sync Tasks | No deduplication, no snapshot-style retention. |
| B2 Object Lock | Incompatible with the lock files of restic ([protection](README.md#protection-against-ransomware-and-stolen-keys)). The restricted keys cover a stolen key; Object Lock would only add protection against a compromise of the B2 account itself. |

## Open points

| Topic | Notes |
| --- | --- |
| Bucket rebuild test | Test the [bucket rebuild](runbook.md#recovery-after-a-deletion-of-the-backups) (rclone copy at T0) on a new throwaway bucket: the test bucket was deleted before this test. Delete the bucket and its keys afterwards. |
| Node down | Backups while a node holding a replica is down, once kube-02 joins ([test](bootstrap.md#tests)). |
| Restore recipe with a HelmRelease | `volsync-restore` was tested on a plain Deployment only: check the suspension and resumption of the HelmReleases, and a StatefulSet, with the first real application. |
| Repository check | Detect a malicious `forget` (the job checks do not): number and age of the snapshots of each repository, compared with the previous run. |
| Restore tests automation | Once applications use VolSync: a nightly CronJob restoring the latest backup of each repository into a throwaway namespace (`replicated-temporary` volumes, read-only B2 keys, resource limits), checking it (`restic check --read-data-subset`, files present, SQLite `PRAGMA integrity_check`), then deleting everything. Never on the production volumes. |
| Logs and metrics backup | With the observability choice. |
| `mbsync` / `vdirsyncer` replacement | At migration. |
| Copy to the NAS | When TrueNAS 27 brings an S3 API, for the cluster repositories only. |
| Kopiur | Look at it again in early 2027 ([checklist](#kopiur-evaluated-to-revisit)). |
