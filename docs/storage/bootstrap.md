# Storage: first deployment

Deploying Piraeus/LINSTOR and checking it. Architecture: [README.md](README.md). On a fresh cluster, the first bootstrap already installs the right schematic and config ([nodes](../nodes/bootstrap.md)) and Flux deploys the storage on its own: only the checks of step 2 are needed.

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kubecluster-01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | The Talos image with the `drbd` extension and the kernel modules `drbd`, `drbd_transport_tcp` and `dm_thin_pool`. | `talos/schematic.yaml`, `talos/patches/drbd.yaml` | Done |
| 1 | The NVMe SSD as an encrypted raw volume `r-storage` on each node. | [nodes](../nodes/bootstrap.md#4-checks-after-the-bootstrap) | Done |
| 2 | Flux running, to apply `kubernetes/apps/piraeus-datastore` and the snapshot-controller. | [cluster/bootstrap.md](../cluster/bootstrap.md#3-bootstrap) | Done |
| 3 | kube-02 joined the cluster (not before: with 2 nodes, losing one also loses the etcd quorum). | [Adding kube-02](../nodes/runbook.md#adding-kube-02) | To do |
| 4 | Disposable NFS export `nas-01-dmz.shelltopia.net:/mnt/vault/kube-test`, nodes authorized, `library/books` writable by the mapped group. | [NFS plan](nfs.md#shares-and-test) | Created |

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

- [x] **A volume of each class, a snapshot and a restore**, in the [`debug` namespace](../cluster/README.md#pod-security) (busybox runs as root):

  ```sh
  kubectl -n debug apply -f - <<'EOF'
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
  kubectl -n debug wait --for=condition=Ready pod/pvctest
  kubectl linstor resource list
  # replicated volume: UpToDate on 2 nodes (the node of the pod and another one); with 3 nodes,
  # a third TieBreaker (diskless) resource. local volume: a single resource without DRBD.
  kubectl -n debug apply -f - <<'EOF'
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
  kubectl -n debug wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/pvctest --timeout=5m
  # The restore PVC fails ("snapshot pvctest not bound") until the snapshot is ready, then the
  # provisioner retries with a growing delay (up to 5 minutes).
  kubectl -n debug wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvctest-restore --timeout=10m
  kubectl -n debug logs pvctest-restore          # hello
  ```

  Expected: the restore pod prints `hello`.

  Clean up. The classes use `reclaimPolicy: Retain`: the PVs stay `Released`, delete them, then their LINSTOR resources ([orphan volumes](runbook.md#orphan-volumes)):

  ```sh
  kubectl -n debug delete pod pvctest pvctest-restore
  kubectl -n debug delete volumesnapshot pvctest
  kubectl -n debug delete pvc pvctest-replicated pvctest-local pvctest-restore
  kubectl delete pv <name>
  kubectl linstor resource-definition delete <pv name>
  ```

## 3. Failover test

- [ ] **Failover.** Once kube-02 has joined, run a pod using a `replicated` volume and power off its node. Then, while the node is away:

  ```sh
  kubectl linstor resource list
  ```

  Expected: the HA controller deletes the pod once the node has lost quorum on the volume, and it restarts on another node with its data, without intervention. The replica of the lost node is `Unknown`/`Outdated`; when the node comes back, DRBD only resynchronizes the blocks written in the meantime.

## 4. Static NFS test

*Partially tested on 2026-11-18.* Independent of the LINSTOR failover test. These ephemeral resources are applied and removed by hand, not by Flux. They only use the disposable `kube-test` export, never the existing media or groupware shares. The `debug` namespace is privileged; the pod itself follows the `restricted` security settings, but this does not test admission in a `restricted` namespace. The test uses UID/GID `65534:65534`, while the NAS maps the group to `dataset-media` (`4002`).

- [x] **Create the test resources.** First make sure there is no existing PV `debug-nfs-test`, PVC `nfs-test` or pod `nfs-test` in `debug`: do not overwrite another test. The PV capacity is required by Kubernetes, not a quota on the NAS.

  ```sh
  kubectl get pv debug-nfs-test
  kubectl -n debug get pvc nfs-test
  kubectl -n debug get pod nfs-test
  ```

  Expected: each command reports `NotFound`. If any resource exists, stop and investigate before continuing.

  ```sh
  kubectl apply -f - <<'EOF'
  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: debug-nfs-test
  spec:
    capacity:
      storage: 1Gi
    accessModes: [ReadWriteMany]
    persistentVolumeReclaimPolicy: Retain
    storageClassName: ""
    mountOptions: [nfsvers=4.2]
    nfs:
      server: nas-01-dmz.shelltopia.net
      path: /mnt/vault/kube-test
    claimRef:
      namespace: debug
      name: nfs-test
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: nfs-test
    namespace: debug
  spec:
    accessModes: [ReadWriteMany]
    storageClassName: ""
    volumeName: debug-nfs-test
    resources:
      requests:
        storage: 1Gi
  ---
  apiVersion: v1
  kind: Pod
  metadata:
    name: nfs-test
    namespace: debug
  spec:
    automountServiceAccountToken: false
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      runAsGroup: 65534
      seccompProfile:
        type: RuntimeDefault
    containers:
      - name: test
        image: docker.io/library/busybox
        command: [sh, -c, 'sleep 86400']
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: [ALL]
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            memory: 32Mi
        volumeMounts:
          - name: share
            mountPath: /mnt/rw
          - name: share
            mountPath: /mnt/ro
            readOnly: true
    volumes:
      - name: share
        persistentVolumeClaim:
          claimName: nfs-test
  EOF
  kubectl -n debug wait --for=condition=Ready pod/nfs-test --timeout=5m
  kubectl -n debug get pvc nfs-test
  kubectl -n debug get pod nfs-test -o wide
  ```

  Expected: the pod is `Ready` and the PVC is `Bound` to `debug-nfs-test`. Note the pod's node for the node-side checks. If the pod is not ready, inspect `kubectl -n debug describe pod nfs-test` and the NAS export and network before continuing.

- [x] **Permissions and read/write.** Check the pod identity and directory permissions, then create a test file without overwriting an existing one:

  ```sh
  kubectl -n debug exec nfs-test -- id
  kubectl -n debug exec nfs-test -- ls -ldn /mnt/rw /mnt/rw/library /mnt/rw/library/books
  kubectl -n debug exec nfs-test -- sh -c 'set -C; echo nfs-test > /mnt/rw/library/books/kubernetes-nfs-test.txt'
  kubectl -n debug exec nfs-test -- ls -ln /mnt/rw/library/books/kubernetes-nfs-test.txt
  kubectl -n debug exec nfs-test -- cat /mnt/rw/library/books/kubernetes-nfs-test.txt
  ```

  Expected: the pod runs as `65534:65534`; the file is created and contains `nfs-test`. The server checks the mapped `nfsnobody:dataset-media` identity, not the pod's primary GID. Check the file owner and group on the NAS too. If the file already exists, the create fails: inspect it rather than overwriting it.

  Observed on kube-03: the pod ran as `65534:65534`, created and read the file; its ownership in the pod was `65534:4002`. The separate NAS-side ownership check remains to confirm.

- [x] **Read-only mount.** Read the same file through the second mount and attempt a write:

  ```sh
  kubectl -n debug exec nfs-test -- cat /mnt/ro/library/books/kubernetes-nfs-test.txt
  kubectl -n debug exec nfs-test -- sh -c 'if echo unexpected >> /mnt/ro/library/books/kubernetes-nfs-test.txt; then echo "ERROR: read-only mount allowed a write"; exit 1; else echo "Write refused as expected"; fi'
  kubectl -n debug exec nfs-test -- cat /mnt/rw/library/books/kubernetes-nfs-test.txt
  ```

  Expected: the read succeeds, the write fails with a read-only filesystem error, and the file still contains only `nfs-test`. Stop if the write succeeds or fails for another reason. Observed on kube-03: all three checks passed.

- [x] **Mount and read-ahead.** Inspect the mount on the node hosting the pod, then follow [checking the NFS read-ahead](../nodes/runbook.md#checking-the-nfs-read-ahead) on that same node:

  ```sh
  talosctl -n <node> read /proc/mounts | grep kube-test
  ```

  Expected: NFS 4.2 (`vers=4.2`) to the test export. Check the actual IPv6 source and return path on the NAS, and the read-ahead as described in the linked procedure. Observed on kube-03: NFS 4.2, a hard mount, `proto=tcp6` and read-ahead `16000` KiB, the expected embedded default. The return path remains to confirm.

- [x] **Clean up.** Remove only the test file, pod, PVC and PV. `Retain` and the static NFS PV do not delete the NAS dataset or export. The resources were recreated for the read-ahead check and need to be removed again; only remove the test file if it was recreated.

  ```sh
  kubectl -n debug exec nfs-test -- rm /mnt/rw/library/books/kubernetes-nfs-test.txt
  kubectl -n debug delete pod nfs-test
  kubectl -n debug delete pvc nfs-test
  kubectl delete pv debug-nfs-test
  ```

  Expected: the Kubernetes resources are gone and the dataset and export still exist on the NAS. Confirm the test file is gone and the rest of the dataset is intact before deciding whether to remove the disposable dataset separately.

  Delete the PVC before the PV: Kubernetes protects a PV that is still bound to a claim. If `kubectl delete pv` waits after the pod is gone, delete the PVC in another terminal, then check both resources. If it still waits, inspect the PV and PVC with `kubectl describe` before taking further action; do not remove protection finalizers to force deletion.

## 5. Static NFS claims

*Not tested yet.* The manifests create the namespace `media` and the two PV/PVC pairs, independently of the application migrations. A bound claim does not prove that the NAS export is reachable: the mount happens when a pod uses it.

- [x] **Flux and binding.** After Flux applies the manifests:

  ```sh
  flux get kustomizations -A
  kubectl get pv media-media backups-groupware
  kubectl -n media get pvc media
  kubectl -n backups get pvc groupware
  ```

  Expected: `media-nfs` and `backups-nfs` are `Ready`; both PVCs are `Bound` to their respective PVs. Test actual access and permissions when the applications are migrated.

## 6. LINSTOR GUI

The Flux Kustomization `linstor-gui` exposes `https://linstor.shelltopia.org/ui/` on the `internal` Gateway. The same `SecurityPolicy` protects `/ui`, `/v1`, `/api` and the OIDC callback and logout paths. `/metrics` is not routed. Controller Auth and LINSTOR tokens remain disabled for existing clients ([decisions](README.md#decisions)).

Before rolling out, follow the [ingress procedure](../ingress/runbook.md#a-ui-without-a-login-of-its-own):

- [x] **Pocket ID.** Create a confidential Pocket ID client with PKCE, restricted to `kubernetes_admins`. Use `https://linstor.shelltopia.org/oauth2/callback` as the redirect URI and `https://linstor.shelltopia.org/` as the logout callback.
- [x] **1Password.** Create `pocket-id-linstor-gui` in the `kubernetes` vault: `username` is the client ID, `credential` the client secret.

- [x] **Root redirect.** `curl -sI https://linstor.shelltopia.org/` should return `302` with a `Location` pointing to `/ui/`. The destination still requires OIDC.
- [x] **Paths.** In a signed-in browser, check that all GUI requests succeed through `/ui/` and `/v1`. From a fresh session, both `/ui/` and `/v1/nodes` must redirect to Pocket ID, not return controller data. `/metrics` must not be routed.
- [x] **Access.** Check the policy is accepted, an administrator can sign in and view nodes, pools and volumes, and an unauthenticated or unauthorized user cannot access the GUI or its API. Test without making storage changes.
- [x] **Bypasses.** Check the route is attached only to the `internal` Gateway, review network policies and Kubernetes access to the controller Service and port-forward, and verify that the intended external access cannot bypass OIDC. OIDC does not protect direct cluster access to the API.
