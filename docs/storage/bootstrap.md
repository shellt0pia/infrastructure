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

## 7. Dynamic NFS trial

*Not deployed.* The [TNS CSI HelmRelease](../../kubernetes/apps/tns-csi/tns-csi/app/helmrelease.yaml) is suspended in Git. The trial uses disposable PVCs only.

- [x] **TrueNAS encryption.** Create `vault/workloads` as a passphrase-protected encryption root, leaving the pool root unencrypted. Create `kubernetes`, `tns.csi.io` and `nfs` beneath it with inherited encryption; do not export `workloads`. Unlock `workloads` after a NAS restart before checking mounts or backups.
- [x] **NFS parent.** Ensure NFS is running. Configure the recursive hourly snapshot task with two weeks of retention. Use the Generic preset and inherit `recordsize` if it is `128 KiB`; otherwise set `128 KiB` on the NFS parent for the trial. Select **LZ4 (Inherit)** and set **Exec** to **Off**. Check the effective properties on the first CSI child dataset, including `encryptionroot=vault/workloads`. Do not share the parent itself. Prepare the [dedicated API account](#truenas-service-account-and-api-key). The CSI can create child datasets and exports; the parent is not an API authorization boundary.
- [x] **1Password.** In the `kubernetes` vault, create `nas-01-tns-csi` with `username` (the dedicated TrueNAS account) and `credential` (its API key). The ExternalSecret supplies the verified-TLS endpoint and syncs the two fields to `tns-csi-truenas`. Check the ExternalSecret reports `Ready` without displaying the key.
- [x] **Activate in Git.** Once the NAS prerequisites are ready, remove `spec.suspend` from the HelmRelease. Wait for the Flux Kustomization and HelmRelease to be `Ready`; check the controller, CSI node registration on each node and the non-default `truenas-nfs` classes. The `replicated` and `linstor` defaults must stay unchanged.
- [x] **Rollout.** The TrueNAS certificate must include `nas-01-dmz.shelltopia.net` in its SANs. The controller started after the SAN was added. The node pods hit a host port conflict on TCP 9808; their health probe uses TCP 19808 instead. Verify that the DaemonSet becomes ready on every node.
- [x] **DNS.** The controller sets `ndots: "1"` so it tries the NAS FQDN before the search suffixes that Cilium denies. After rollout, check Hubble for the exact query without the suffixed refusals.
- [ ] **Validate.** Follow the [disposable-volume checks](nfs.md#4-validation-and-recovery), including the mount source and export allowlist. Do not migrate applications until the TrueNAS backup and restore are validated.

### TrueNAS service account and API key

1. In **Credentials → Local Groups**, check that GID `2002` is free and create `tns-csi` with that GID. Assign the built-in **Sharing Administrator** privilege (`SHARING_ADMIN` API role) to the dedicated group. Do not assign Full Administrator or sudo. The [TrueNAS RBAC reference](https://api.truenas.com/v25.10/rbac.html#sharing-admin) documents this role; it can manage datasets, shares and ACLs across the NAS, not just the CSI subtree.
2. In **Credentials → Local Users**, check that UID `2002` is free and create `tns-csi` with that UID and the existing `tns-csi` primary group. Do not add other privileged groups. Disable password login and do not configure SSH credentials, SMB access or sudo; use a non-login shell if available. This is the API identity, not the NFS file owner or the UID of an application pod.
3. From the administrator session, open **API Keys** from the top-right account menu and add `kubecluster-01-tns-csi` for user `tns-csi`. Set an expiration that covers the trial and record a renewal reminder. The key inherits the account's privileges; it does not have a separate dataset scope.
4. Store the generated key directly in `kubernetes/nas-01-tns-csi` in 1Password (`username: tns-csi`, `credential`: the key). Do not paste it into Git, a shell command or a ticket. Keep the API on `wss://` with certificate verification.
5. Validate provisioning, expansion, snapshots and deliberate retirement with disposable volumes. If an API call is denied, identify the exact method and check the role before changing permissions. Do not fall back to Full Administrator by default.

## 8. TNS CSI dashboard and metrics

- [ ] In Pocket ID, create a confidential client with redirect `https://tns-csi.shelltopia.org/oauth2/callback` and allow only `kubernetes_admins`. In the `kubernetes` vault, create `pocket-id-tns-csi` with `username` (client ID) and `credential` (client secret).
- [ ] After Flux reconciles `tns-csi-dashboard`, check that `/` redirects to `/dashboard/`. In a private browser, both `/dashboard/` and `/dashboard/api/volumes` must require login; a viewer must not get access. Check that the administrator sees the inventory and that `/metrics` is not routed. OIDC guards the Gateway route, not direct access to the in-cluster Service.
- [ ] In Grafana, open **TNS CSI Overview** and verify the connection and NFS panels against VictoriaMetrics. In VMAgent, check the controller target is up. Check that VMAlert loaded `TNSCSITrueNASDisconnected`; it covers a scraped connection gauge at zero for five minutes, not a missing scrape or a crashed controller.
