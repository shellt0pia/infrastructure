# Storage: runbook

Day-to-day operations on the volumes. Architecture: [README.md](README.md). The LINSTOR commands use the `kubectl linstor` plugin (installed by mise).

## Orphan volumes

The StorageClasses use `reclaimPolicy: Retain`: when a PVC is deleted, its PV stays `Released` and its data stays in LINSTOR. To remove a volume for good:

1. **Delete the PV:**

   ```sh
   kubectl delete pv <name>
   ```

2. **Delete its LINSTOR resources:**

   ```sh
   kubectl linstor resource-definition delete <pv name>
   ```

The volumes of the `replicated-temporary` class (`reclaimPolicy: Delete`) are cleaned up on their own ([backups](../backups/README.md)).

## Bringing a volume back to 2 replicas

After [rebuilding a node](../nodes/runbook.md#rebuilding-a-node):

1. **Check the replicas:**

   ```sh
   kubectl linstor resource list
   ```

   Expected: the `replicated` volumes are back to 2 replicas.

2. **Otherwise, adjust the resource group:**

   ```sh
   kubectl linstor resource-group adjust replicated
   ```

## Removing a lost node

The operator keeps a deleted node registered by default (`deletionPolicy: Retain`), so this is needed when a node is rebuilt: its volumes will not exist on the wiped disk ([rebuilding a node](../nodes/runbook.md#rebuilding-a-node)).

```sh
kubectl linstor node lost kube-0X
```

Expected: the node and its replicas are removed from LINSTOR.

## Checking the state

```sh
kubectl linstor node list
kubectl linstor storage-pool list
kubectl linstor resource list
```

Expected:

- every node `Online`;
- the `nvme` pool of each node, with its free capacity;
- the replicas of each volume: `UpToDate` on 2 nodes plus a diskless `TieBreaker` on the third one is the nominal state of a `replicated` volume. After a node was away, `Unknown`/`Outdated` then a resynchronization of the blocks written in the meantime.

## Replacing a failed disk

The disks are selected by their identifier in `talos/nodes/kube-0X.yaml` (WWID of the SATA SSD, serial of the NVMe SSD, [hardware](../nodes/README.md#hardware)), and a new disk has a new one. Replacing either of them comes down to [rebuilding the node](../nodes/runbook.md#rebuilding-a-node): Talos and the encrypted storage volume are recreated, and the replicas are copied back from the other node.

- [ ] **Assess what is lost:**

  ```sh
  kubectl linstor storage-pool list
  kubectl linstor resource list
  ```

  Expected, for a failed NVMe SSD: the `nvme` pool of the node in error. The `replicated` volumes stay available from the other node. The volumes of the `local` class of this node are lost: [restore them from the backups](../backups/runbook.md#one-application-volume-from-scratch).

- [ ] **Replace the disk**, then fill its new identifier in `talos/nodes/kube-0X.yaml` (WWID for a SATA SSD, serial for an NVMe SSD, read with `talosctl get disks --insecure` in maintenance mode, [first boot](../nodes/bootstrap.md#3-first-boot-in-maintenance-mode)).
- [ ] **Rebuild the node:** [rebuilding a node](../nodes/runbook.md#rebuilding-a-node). With the failed disk, the node may not boot at all: start from the ISO.
- [ ] **Replicas.** Check that the volumes are back to 2 replicas, [adjust](#bringing-a-volume-back-to-2-replicas) otherwise.

## The thin pool is filling up

LINSTOR allows overcommitting the thin pool by default: the volumes can be bigger than the NVMe SSD, and the pool only fills as they are written ([open points](evaluations.md#open-points)). Until the metrics stack is there, check it by hand from time to time.

- [ ] **Free capacity of each pool:**

  ```sh
  kubectl linstor storage-pool list
  kubectl linstor volume list
  ```

- [ ] **Free space.** Delete what nothing uses anymore: the [orphan volumes](#orphan-volumes) (`Released` PVs, their data stays in LINSTOR), and the snapshots left behind:

  ```sh
  kubectl get pv | grep Released
  kubectl linstor snapshot list
  ```

  Expected: only the snapshot of each ReplicationDestination ([backups](../backups/README.md)).

- [ ] **Limit the overcommit**, to stop volumes from being provisioned past what the disk can hold: set `MaxOversubscriptionRatio` on the `LinstorCluster` in `kubernetes/apps/piraeus-datastore`.
