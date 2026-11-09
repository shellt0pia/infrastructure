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

## SELinux label of an existing volume

The StorageClasses mount the volumes with the `ephemeral_t` SELinux context ([decisions](README.md#decisions)). The option is copied into each PV at its creation: the PVs created before it are mounted without it, their files are `unlabeled_t` and every write of a pod is an AVC denial.

1. **Find the PVs without the option:**

   ```sh
   kubectl get pv -o custom-columns='PV:.metadata.name,SC:.spec.storageClassName,NS:.spec.claimRef.namespace,PVC:.spec.claimRef.name,OPTS:.spec.mountOptions'
   ```

   Expected: `<none>` in `OPTS` for the LINSTOR PVs to patch.

2. **Patch the PV:**

   ```sh
   kubectl patch pv <pv> --type merge -p '{"spec":{"mountOptions":["context=system_u:object_r:ephemeral_t:s0"]}}'
   ```

3. **Mount it again**, the option only applies to a new mount: delete the pod that uses it. A VolSync cache volume is mounted again at the next sync.

   ```sh
   kubectl -n <namespace> delete pod <pod>
   ```

4. **Check the mount** on the node of the new pod:

   ```sh
   talosctl -n <node> read /proc/mounts | grep <pv>
   ```

   Expected: `context="system_u:object_r:ephemeral_t:s0"` in the options, and no new `unlabeled_t` denial in VictoriaLogs (`log_source:talos-service "talos-service":auditd unlabeled_t`).

## Mounting a NAS share

The shares of the NAS already exist, with their data: a static PersistentVolume points to one, nothing is provisioned. The inline `nfs` pod volumes are forbidden by [Pod Security](../cluster/README.md#pod-security). A PV binds a single PVC: one PV per share and per namespace that mounts it, named `<namespace>-<share>`, next to the application (in `app/`).

```yaml
---
# The <share> share of the NAS, for <namespace>. Deleting the PV never touches the data
# (Retain, no provisioner).
apiVersion: v1
kind: PersistentVolume
metadata:
  name: <namespace>-<share>
spec:
  capacity:
    storage: 1Ti # required, not enforced on NFS
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - nfsvers=4.2
  nfs:
    server: <NAS>
    path: <export path>
  claimRef:
    namespace: <namespace>
    name: <share>
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <share>
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: "" # otherwise the default class (replicated) provisions a LINSTOR volume
  volumeName: <namespace>-<share>
  resources:
    requests:
      storage: 1Ti
```

- **Binding**: `volumeName` on the PVC and `claimRef` on the PV, so that neither binds to anything else.
- **Read-only**: `readOnly: true` on the `volumeMount` of the pod (Plex, Navidrome).
- **Permissions**: the exports use `mapall=<uid>`, every access is done as that UID on the NAS, whatever the UID of the pod. `fsGroup` does not apply to NFS volumes. An application that checks the owner of its files runs with the same UID (`runAsUser`).
- **Network**: the kubelet of the node mounts the share, not the pod: the network policies do not apply, the exports must allow the nodes subnet.
- **User namespaces**: a pod with an NFS volume cannot use `hostUsers: false` (no idmapped mounts on NFS).

- [ ] **Check:**

  ```sh
  kubectl -n <namespace> get pvc <share>
  kubectl -n <namespace> exec <pod> -- grep nfs /proc/mounts
  ```

  Expected: the PVC is `Bound` to `<namespace>-<share>`, the mount shows `vers=4.2`.
