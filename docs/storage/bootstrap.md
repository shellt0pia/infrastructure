# Storage: first deployment

Deploying Piraeus/LINSTOR and checking it. Architecture: [README.md](README.md). On a fresh cluster, the first bootstrap already installs the right schematic and config ([nodes](../nodes/bootstrap.md)) and Flux deploys the storage on its own: only the checks of step 2 are needed.

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kube-cluster01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | The Talos image with the `drbd` extension and the kernel modules `drbd`, `drbd_transport_tcp` and `dm_thin_pool`. | `talos/schematic.yaml`, `talos/patches/drbd.yaml` | Done |
| 1 | The NVMe SSD as an encrypted raw volume `r-storage` on each node. | [nodes](../nodes/bootstrap.md#4-checks-after-the-bootstrap) | Done |
| 2 | Flux running, to apply `kubernetes/apps/piraeus-datastore` and the snapshot-controller. | [cluster/bootstrap.md](../cluster/bootstrap.md#3-bootstrap) | Done |
| 3 | kube-02 joined the cluster (not before: with 2 nodes, losing one also loses the etcd quorum). | [Adding kube-02](../nodes/runbook.md#adding-kube-02) | To do |

## 1. Prepare the nodes

Only for a cluster bootstrapped before the storage was added: the nodes need the `drbd` extension and the kernel modules **before** Flux applies `kubernetes/apps/piraeus-datastore` (otherwise the satellites fail until then).

- [x] **Node by node.** One node at a time, apply the kernel modules, then upgrade to the new schematic (with `siderolabs/drbd`, reboots the node):

  ```sh
  just talos apply-node kube-0X
  just talos upgrade-node kube-0X
  talosctl health                                         # before the next node
  ```

- [x] **Checks on each node:**

  ```sh
  talosctl get extensions
  talosctl read /proc/modules
  talosctl read /sys/module/drbd/parameters/usermode_helper
  ```

  Expected: `drbd` is listed. `drbd`, `drbd_transport_tcp` and `dm_thin_pool` are loaded. `usermode_helper` is `disabled`.

## 2. Deploy and check

- [x] **Deployment.** Push the manifests, then:

  ```sh
  flux get ks -A
  ```

  Expected: `snapshot-controller`, `piraeus-operator` and `piraeus-cluster` are `Ready` (`piraeus-cluster` waits for the two others).

- [x] **Snapshot API:**

  ```sh
  kubectl api-resources --api-group=snapshot.storage.k8s.io
  ```

  Expected: `volumesnapshots`, `volumesnapshotcontents` and `volumesnapshotclasses`.

- [x] **Piraeus:**

  ```sh
  kubectl -n piraeus-datastore get linstorcluster,linstorsatellites,pods -o wide
  ```

  Expected: every condition `True`, one `linstor-satellite`, `linstor-csi-node` and `ha-controller` pod per node, the satellites with the node IPv4 and ULA addresses (host network).

- [x] **LINSTOR nodes** (`kubectl-linstor` plugin, installed by mise):

  ```sh
  kubectl linstor node list
  kubectl linstor node interface list kube-01             # same for each node
  kubectl linstor node list-properties kube-01
  ```

  Expected: every node `Online`. The interfaces are `default-ipv4` and `default-ipv6` (ULA address, never the GUA one), and `PrefNic` is `default-ipv6`.

- [x] **Storage pools:**

  ```sh
  kubectl linstor storage-pool list
  ```

  Expected: one `nvme` pool (`LVM_THIN`, `linstor_nvme/nvme`) per node, with about 1 TB of capacity, plus the `DfltDisklessStorPool`.

- [x] **Classes:**

  ```sh
  kubectl get storageclass,volumesnapshotclass
  ```

  Expected: `replicated (default)`, `local` and `linstor`.

- [x] **A volume of each class, a snapshot and a restore:**

  ```sh
  kubectl apply -f - <<'EOF'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pvctest-replicated
  spec:
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 1Gi
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pvctest-local
  spec:
    storageClassName: local
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 1Gi
  ---
  apiVersion: v1
  kind: Pod
  metadata:
    name: pvctest
  spec:
    containers:
      - name: pvctest
        image: docker.io/library/busybox
        command: [sh, -c, 'echo hello > /replicated/test && echo hello > /local/test && sleep infinity']
        volumeMounts:
          - name: replicated
            mountPath: /replicated
          - name: local
            mountPath: /local
    volumes:
      - name: replicated
        persistentVolumeClaim:
          claimName: pvctest-replicated
      - name: local
        persistentVolumeClaim:
          claimName: pvctest-local
  EOF
  kubectl wait --for=condition=Ready pod/pvctest
  kubectl linstor resource list
  # replicated volume: UpToDate on 2 nodes (the node of the pod and another one); with 3 nodes,
  # a third TieBreaker (diskless) resource. local volume: a single resource without DRBD.
  kubectl apply -f - <<'EOF'
  apiVersion: snapshot.storage.k8s.io/v1
  kind: VolumeSnapshot
  metadata:
    name: pvctest
  spec:
    source:
      persistentVolumeClaimName: pvctest-replicated
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pvctest-restore
  spec:
    dataSource:
      apiGroup: snapshot.storage.k8s.io
      kind: VolumeSnapshot
      name: pvctest
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 1Gi
  ---
  apiVersion: v1
  kind: Pod
  metadata:
    name: pvctest-restore
  spec:
    restartPolicy: Never
    containers:
      - name: pvctest
        image: docker.io/library/busybox
        command: [cat, /restore/test]
        volumeMounts:
          - name: restore
            mountPath: /restore
    volumes:
      - name: restore
        persistentVolumeClaim:
          claimName: pvctest-restore
  EOF
  kubectl wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/pvctest --timeout=5m
  # The restore PVC fails ("snapshot pvctest not bound") until the snapshot is ready, then the
  # provisioner retries with a growing delay (up to 5 minutes).
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvctest-restore --timeout=10m
  kubectl logs pvctest-restore          # hello
  ```

  Expected: the restore pod prints `hello`.

  Clean up. The classes use `reclaimPolicy: Retain`: the PVs stay `Released`, delete them, then their LINSTOR resources ([orphan volumes](runbook.md#orphan-volumes)):

  ```sh
  kubectl delete pod pvctest pvctest-restore
  kubectl delete volumesnapshot pvctest
  kubectl delete pvc pvctest-replicated pvctest-local pvctest-restore
  kubectl delete pv <name>
  kubectl linstor resource-definition delete <pv name>
  ```

## 3. Failover test

- [ ] **Failover.** Once kube-02 has joined, run a pod using a `replicated` volume and power off its node. Then, while the node is away:

  ```sh
  kubectl linstor resource list
  ```

  Expected: the HA controller deletes the pod once the node has lost quorum on the volume, and it restarts on another node with its data, without intervention. The replica of the lost node is `Unknown`/`Outdated`; when the node comes back, DRBD only resynchronizes the blocks written in the meantime.
