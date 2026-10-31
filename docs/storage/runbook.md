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
