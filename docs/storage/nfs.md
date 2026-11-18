# NFS storage

Temporary document: the plan of the two NFS items of the [Storage](../roadmap.md#storage) section of the roadmap, step by step, as in [cluster-tools](../cluster-tools.md). Each step writes its decisions in the topic documents and ticks its item of the roadmap in the same commit ([AGENTS.md](../../AGENTS.md#do-not)). This document is deleted after the last step.

## Steps

| Step | Roadmap items | Why in this order | Status |
| --- | --- | --- | --- |
| [1](#1-static-nfs-volumes) | Access to the existing shares of the NAS | Checks NFS, the network and the Talos mounts without a CSI driver. | To do |
| [2](#2-dynamic-nfs-volumes) | A CSI driver for the data of Immich and Nextcloud | Once the NFS path works: the driver adds the provisioning of the datasets and exports, not another storage backend. | TNS CSI proposed; to validate |
| [3](#3-monitoring-and-administration) | Metrics, dashboards, kubectl plugin | Before the tests: the failures must be visible. Part of the second roadmap item. | To do |
| [4](#4-validation-and-recovery) | Checks of the CSI, recovery and backups | Before moving the data of the applications. Part of the second roadmap item. | To do |

## 1. Static NFS volumes

### Today

- TrueNAS SCALE 25.10.8, ZFS datasets on the NAS. The existing shares are managed on the NAS, independently of Kubernetes.
- Piraeus/LINSTOR is deployed: `replicated` (default, 2 replicas), `local`, `replicated-temporary` and the `linstor` VolumeSnapshotClass (default). The snapshot-controller is already deployed ([storage](README.md#decisions)). None of this changes.
- The [runbook](runbook.md#mounting-a-nas-share) defines the static PV and PVC pattern. NFS 4.2, one PV per share and per namespace, explicit binding in both directions, `storageClassName: ""` and `Retain`. No CSI needed for these shares.
- Talos has `nfsrahead`; the [check](../nodes/runbook.md#checking-the-nfs-read-ahead) waits for an NFS volume mounted by a pod.
- The [network](../network/README.md#nas-no-asymmetric-path): the NAS has an interface on the nodes subnet; its default routes stay on its main interface. The [nodes subnet](../network/README.md#nodes-subnet) is the source of the mounts, not the pod or Service networks.

### Decisions

- Keep the static NFS PVs for datasets that already hold files (media, mail/calendar archives, external libraries of Immich). Nothing in Kubernetes creates or deletes these datasets. The PV capacity is required by Kubernetes, not a quota on the NAS.
- A share that an application only reads is mounted read-only. For an external library of Immich, this is the default unless an application feature needs writes.
- The two patterns are separate: static PVs for existing shares, dynamic PVCs for storage owned by an application. No adoption of the static shares by the CSI, and no inline `nfs` volume (`restricted` [Pod Security](../cluster/README.md#pod-security)).
- Keep the permissions of the existing exports: Mapall User `nfsnobody` and a Mapall Group with write access to the share ([runbook](runbook.md#mounting-a-nas-share)). The server maps client credentials to these identities; the pod's UID/GID need not match them. Check actual access and ownership in the pod; do not assume that `fsGroup` changes the NAS permissions. No `hostUsers: false` (no idmapped mounts on NFS).
- Validate with the disposable export `nas-01-dmz.shelltopia.net:/mnt/vault/kube-test` before migrating services. It is created and the Kubernetes hosts are authorized. Its intended Mapall User is `nfsnobody` (UID `65534`), its Mapall Group `dataset-media` (GID `4002`). The test pod uses UID/GID `65534:65534`.

### Shares and test

The two existing exports are intended for the future applications, not for the disposable test. A PV binds one PVC in one namespace: if consumers use different namespaces, each namespace needs its own PV/PVC for the same export.

| Export on `nas-01-dmz.shelltopia.net` | Consumers | Access |
| --- | --- | --- |
| `/mnt/vault/media` | Media stack, including Sonarr, SABnzbd and Plex; PVC `media` in `media` | Mostly read/write; Plex currently mounts its library directories read-only. |
| `/mnt/vault/backups/groupware` | mbsync (`emails`), vdirsyncer (`calendars`, `contacts`); PVC `groupware` in `backups` | Separate directories; access to confirm at migration. |
| `/mnt/vault/kube-test` | Disposable test only | Read/write and read-only checked on kube-03; [test](bootstrap.md#4-static-nfs-test) not complete. |

The existing media hierarchy has `root:dataset-media` directories with mode `0750` for `media` and `media/library`, and `0775` for `media/library/books`. The test export reproduces this layout; its writable directory is `library/books`. The mapped group can traverse the first two directories but cannot write there. Test writes in the group-writable child, not at the export root.

The FQDN has an AAAA record only. The existing exports authorize the Kubernetes nodes by host. The kube-03 test mounted over IPv6; the return path remains to check. The group mapped by the groupware export is to confirm.

### Plan

- [x] **NAS.** The user created the test dataset and export and authorized the nodes. The kube-03 mount used IPv6; the return path remains to check. NFSv4 uses TCP 2049.
- [x] **Test.** Run the ephemeral PV, PVC and pod in [bootstrap](bootstrap.md#4-static-nfs-test). Check binding, mapped permissions, read/write and read-only mounts, NFS 4.2 and read-ahead. Deleting the test PV must not touch the dataset.
- [x] **Deploy and document.** The two Flux-managed PV/PVC pairs are ready; check their binding once deployed. Update [bootstrap](bootstrap.md), [storage](README.md#status), [evaluations](evaluations.md#open-points) and the first NFS item of the [roadmap](../roadmap.md#storage) once verified.

## 2. Dynamic NFS volumes

### Starting point

The second NFS item of the roadmap names `truenas-csi` or `democratic-csi` for Immich and Nextcloud. Their data should stay on the NAS, but a deployment of an application should not need a dataset and an export created by hand first. A PVC declares the size; the CSI provisions a dataset and an export on TrueNAS, and the node plugin mounts it.

| Data | Storage |
| --- | --- |
| Databases (CNPG for Immich and Nextcloud), application state that needs block storage | `replicated` |
| Immich uploads and library managed by Immich, Nextcloud `data` | Dynamic NFS PVCs |
| Existing media, external libraries, archives | Static NFS PVs |

A NAS is still one failure domain. ZFS redundancy and snapshots do not give the availability of the replicated LINSTOR volumes. No PostgreSQL data directory on NFS ([Immich requirements](https://docs.immich.app/install/requirements/)).

### Upstream

| Driver | NFS provisioning | Notes |
| --- | --- | --- |
| [TNS CSI](https://github.com/fenio/tns-csi) (`tns.csi.io`) | One ZFS dataset and export per volume, through the WebSocket API | CSI snapshots, clones, expansion, ZFS properties, volume adoption, kubectl plugin, web dashboards, metrics, Grafana. Upstream explicitly calls it early development, not production-ready. |
| [TrueNAS CSI](https://github.com/truenas/truenas-csi) (`csi.truenas.io`) | One ZFS dataset and export per volume, through the WebSocket API | Official driver, TrueNAS 25.10+, CSI snapshots, clones, expansion, ZFS properties, scheduled snapshots, Prometheus metrics and a Grafana dashboard. The fallback if TNS CSI does not pass the tests. |
| [democratic-csi](https://github.com/democratic-csi) | One ZFS dataset and export per volume with the TrueNAS ZFS NFS driver | Older, mature project; supports several backends and TrueNAS generations. More configuration choices (API and/or SSH, depending on the driver). No need for the other backends here. |
| [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs) (`nfs.csi.k8s.io`) | A directory per volume under an existing export | No NAS API credentials, simpler driver, but no per-PVC ZFS dataset, native ZFS quota, snapshot or clone. Its directory-level snapshots are not ZFS snapshots. |

Both TrueNAS-specific drivers fit 25.10.8. The [comparison of TNS CSI](https://github.com/fenio/tns-csi) is useful for the workflow differences, not as the source of the current features of the official driver: its NFS, metrics, Grafana and NVMe-oF support are in its own README and [chart](https://github.com/truenas/truenas-csi/tree/master/charts/truenas-csi).

TNS CSI upstream documents Talos compatibility and CSI sanity and integration tests. Its README also says the auxiliary compatibility/stress workflows are disabled pending their migration. These are not tests of this cluster, its exact Talos version, its SELinux policy or the selected chart release.

### Answers

1. **Driver:** TNS CSI, subject to the tests of [step 4](#4-validation-and-recovery). The kubectl plugin, inventory dashboards and adoption of retained volumes are the advantages over the official driver. Metrics alone are no longer a differentiator. The official driver is the fallback, not a second driver to deploy alongside TNS CSI.
2. **Protocol:** NFS only. Neither iSCSI, NVMe-oF nor SMB used; LINSTOR already provides the block storage. One ZFS dataset per PVC for quotas, snapshots and independent recovery, rather than the subdirectories of `csi-driver-nfs`.
3. **Class:** `truenas-nfs`, not default (`replicated` stays so), `Retain`, `Immediate`, expansion allowed, NFS 4.2 with hard mounts. `ReadWriteMany` where the application needs shared access; it does not make concurrent application writers safe. A separate `truenas-nfs` VolumeSnapshotClass, not default (`linstor` stays so), with `deletionPolicy: Retain` proposed for manual snapshots. Its retention is a separate decision from that of the PVs.
4. **Datasets:** a dedicated parent dataset for the cluster, separate from the existing shares; the actual pool, path and name of the datasets to decide before the release. No static dataset/export per application. Compression inherited or `lz4`, `sync` not disabled, no deduplication. Check the quota and reservation behaviour rather than assuming that the PVC size reserves space. The names or ZFS metadata must let the NAS backup and recovery procedures map a dataset to its application.
5. **GitOps:** the OCI chart of TNS CSI (`oci://registry-1.docker.io/bfenski/tns-csi-driver`, [deployment](https://github.com/fenio/tns-csi/blob/main/docs/DEPLOYMENT.md)), through an `OCIRepository` and `HelmRelease`, not an imperative Helm install. Pin the version as in the [convention](../conventions.md#charts), Renovate follows it. Proposed namespace and application: `tns-csi/tns-csi`. The namespace is privileged for the node plugin (host mounts and mount propagation); the application namespaces stay `restricted`.
6. **Resources:** requests and memory limits of the [convention](../conventions.md#resources-and-priorities) for every container, no CPU limits. `system-node-critical` for the CSI node plugin; `system-cluster-critical` proposed for the controller as for the storage controllers. Check the defaults and sidecars in the render, then the usage in VictoriaMetrics and Goldilocks.
7. **Secrets:** one TrueNAS API key for the driver, used through `wss://` with certificate verification. The item `nas-01-tns-csi` proposed in the `kubernetes` vault, synced through an `ExternalSecret` and the `onepassword` ClusterSecretStore ([secrets](../conventions.md#secrets)). Never a key in Helm values or a command line. Verify the existing Secret fields of the chart, the API roles required, and whether the rights can be limited to the CSI datasets (do not assume a parent dataset is an API authorization boundary).
8. **Network:** API access from the CSI components that need it, by FQDN, not from the application pods. An egress policy as in the [convention](../conventions.md#network-policies) for pod-networked components; inspect `hostNetwork` and the host policy for the node plugin. NFS data traffic from the nodes to the NAS. The generated exports allow the nodes subnet only, not every host. API availability and NFS availability are different: the tests check both.

### StorageClass

Candidate manifest, not tested yet. The chart can also generate the class; use one source only. The pool, parent dataset and server are placeholders, not decisions.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nfs
provisioner: tns.csi.io
parameters:
  protocol: nfs
  pool: <pool>
  parentDataset: <parent-dataset>
  server: <NAS-FQDN>
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.2
  - hard
```

`parentDataset` is relative to the pool ([deployment](https://github.com/fenio/tns-csi/blob/main/docs/DEPLOYMENT.md)). The export restrictions, permissions and other ZFS properties are left out until checked against the pinned release. The optional `deleteStrategy: retain` is a driver-side safeguard, not a replacement for `reclaimPolicy: Retain`; decide after the lifecycle and adoption tests.

### Questions

- **Permissions.** Can one class serve both applications with their intended UIDs/GIDs, or does each need its own export mapping or dataset ownership? Check the NFS parameters of the pinned release, root squashing, ACLs, `fsGroupPolicy` and the actual owner seen in the pod. Do not give every client root access to make `chown` work. NFS `AUTH_SYS` trusts the client; network and server permissions matter more than the PVC access mode.
- **Talos.** Does the node plugin mount the kubelet directories with the propagation Talos needs? Check SELinux on the NFS mounts and the reads/writes under `restricted` before enforcing SELinux. Do not copy the `ephemeral_t` mount option of LINSTOR without checking NFS and its label support. Check the `nfsrahead` setup on the CSI mounts too.
- **Dataset layout.** Name of the pool and the parent dataset, whether PVC names or UUIDs are used, and the layout of the Backrest sources. Do not assume that a newly created child ZFS dataset is included in a TrueNAS App's existing parent mount.
- **Secrets and TLS.** Exact API FQDN, certificate trust, minimum roles and rotation without dropping mounts; check whether the plugin needs to read the driver Secret. No access for `kubernetes_viewers` to that Secret.
- **Retention.** How to rebind a retained PV in the same cluster, adopt it in a rebuilt cluster, and explicitly retire a dataset after a backup. What happens to its export and its snapshots at each step? A released PV is not a free volume. No automatic orphan cleanup.

### Plan

- [ ] **NAS**, by the user: the parent dataset, NFS service, API account and key in 1Password, with the permissions and the TLS certificate decided above.
- [ ] **Render.** Select the chart release, read its values and changelog. Render the NFS-only configuration: Secret reference, StorageClass, controller and node plugin (host paths, propagation, privileges, RBAC, priority classes, resources and metrics). No other protocol classes and no extra default class.
- [ ] **Manifests.** The Flux application, namespace, `ExternalSecret`, dependencies on `external-secrets-stores` and the Prometheus CRDs when the monitors are enabled, and the policy. The StorageClass and VolumeSnapshotClass, either from the chart or manifests of the app. Local checks: `flux build`, `helm template`, kubeconform. No direct apply to the cluster.
- [ ] **Deploy and check.** The Kustomization and HelmRelease `Ready`, controller available, CSI node pod and registration on each node, `tns.csi.io` registered, both new classes non-default. The `replicated` and `linstor` defaults unchanged. Before application PVCs, [step 3](#3-monitoring-and-administration) and [step 4](#4-validation-and-recovery).

## 3. Monitoring and administration

### Today

The cluster runs VictoriaMetrics (`VMAgent`, `VMSingle`, `VMAlert`), not kube-prometheus-stack. The operator converts the `ServiceMonitor` and `PodMonitor` CRDs, and `VMAgent` selects monitors of every namespace. Grafana is its own release in `observability`; its sidecars read ConfigMaps there, with `grafana_dashboard: "1"` and Prometheus data source UID `VictoriaMetrics` ([observability](../observability/README.md)). Do not widen their rights to Secrets or all namespaces for one dashboard.

### Upstream

- [TNS CSI](https://github.com/fenio/tns-csi): `controller.dashboard.enabled: true`, port 9090 by default, for the in-cluster inventory. The kubectl plugin also starts a local dashboard (`kubectl tns-csi dashboard`, port 2137).
- `grafana.dashboards.enabled: true` creates a dashboard ConfigMap. The deployment guide describes discovery by kube-prometheus-stack; here check the namespace, labels and data source references first.
- The kubectl plugin (`kubectl krew install tns-csi`) includes `summary`, `list`, `list-snapshots`, `health`, `troubleshoot <pvc>` and `dashboard`. It can discover the credentials of the driver. It also has destructive commands (`cleanup`); not used as part of normal operations.

### Answers

1. **Metrics:** enable the endpoint and the ServiceMonitor of the chart. Check its coverage of the controller, node plugin and sidecars, and whether a host port is exposed (port conflicts and the host policy). The existing scraper and converted monitors do the work, no other Prometheus instance. Monitor API health, operation errors and latency, missing scrape targets, failed provisioning and capacity where exported. The pool capacity and disks still need monitoring of TrueNAS itself ([external devices](../observability/README.md#external-devices)).
2. **Grafana:** use the upstream dashboard. If its ConfigMap cannot be rendered in `observability` with the right data source and labels, vendor the JSON of the pinned version next to the Grafana release, like the other dashboards. Do not grant more RBAC to Grafana. Check the queries on VictoriaMetrics, and disable Flux substitution on its ConfigMap when it contains Grafana variables.
3. **Inventory:** enable the controller dashboard, port-forward only at first. No route on the `external` Gateway, and no anonymous route on `internal` either: check its authentication, the APIs it exposes and the rights of its ServiceAccount before considering an `HTTPRoute` with OIDC protection. The UI is not a substitute for the access checks of Kubernetes ([OIDC](../cluster/README.md#oidc-authentication)).
4. **CLI:** the plugin on the workstation (Krew or a pinned release). Use the read-only commands for inventory and troubleshooting. Check its RBAC and how it obtains its TrueNAS credentials; a Kubernetes viewer must not gain NAS write rights by running it. No cleanup or adoption without an explicit recovery procedure.

### Plan

- [ ] **Metrics.** The monitor selected by `VMAgent`, the metrics in VictoriaMetrics, tested through the API outage of step 4; alert rules next to the application, tuned as in [alerting](../observability/README.md#alerting). Include a capacity alert or use the NAS metrics if the driver does not expose the needed series.
- [ ] **Grafana.** The dashboard discovered in `observability`, queries populated and data source selected. Review its panels after the first provisioning and the first failed operation.
- [ ] **Inventory.** Port-forward the dashboard Service and check the volume, its PVC, snapshots and health. Install the plugin on the workstation, check the same inventory and its permissions with the OIDC identities.
- [ ] **Docs.** The tools and rules in [observability](../observability/README.md), the commands in [runbook](runbook.md), the names, ports and 1Password item in [reference](../reference.md) once decided.

## 4. Validation and recovery

*Not tested yet.* All the tests use disposable datasets and volumes, never the data of Immich or Nextcloud. The destructive parts are performed by the user, separately from the read-only checks ([AGENTS.md](../../AGENTS.md#commands)).

### Checks

- [ ] **Provision.** A throwaway PVC with `storageClassName: truenas-nfs`, a small requested size, and a non-root pod. Expected: the PVC `Bound`, PV with driver `tns.csi.io` and policy `Retain`, exactly one child dataset and one NFS export, actual NFS 4.2 hard mount (not a local directory). The export only allows the nodes subnet.
- [ ] **Permissions and RWX.** The intended UID/GID of each application can read, create, rename and delete its files; a pod using another UID gets the intended access only. Two pods on different nodes see the same test file. Check SELinux, read-ahead and the user namespace limitation. No change to application Pod Security.
- [ ] **Quota and expansion.** Fill a small test dataset to its limit and check the error, increase the PVC request, and check the dataset quota and usable space from the mounted volume. Existing files still readable; other datasets unaffected.
- [ ] **Snapshots.** A `VolumeSnapshot` naming the `truenas-nfs` snapshot class explicitly, restore into a new PVC, compare the file checksums. Check a clone and the deletion/retention of the snapshot separately from the source volume. `linstor` remains the default.
- [ ] **API interruption.** Interrupt the API in a controlled test without stopping NFS. Existing mounts still serve data if NFS is up; provisioning fails or retries visibly, then converges after the API comes back. No duplicate exports or datasets. Verify metrics and alerts.
- [ ] **NAS and node restart.** Restart the NAS in a maintenance window, check that the hard mounts resume (I/O may block during the outage). Restart a node and reschedule a test pod to another node; compare the data. Restart the controller/node plugin and test a chart upgrade using the same disposable PVC. Check for duplicate shares and stale mounts.
- [ ] **Retention.** Remove a test PVC through Git. Expected: the released PV is retained with its files and share. Check rebind and deliberate retirement, including snapshots. Test `deleteStrategy` separately if it is enabled. No cleanup against a live application.
- [ ] **Adoption.** On a throwaway cluster or in a controlled recovery rehearsal, recreate the driver and claims, and adopt the retained dataset using the [upstream adoption procedure](https://github.com/fenio/tns-csi). This is for TNS CSI-managed datasets with `tns-csi:*` identity metadata, not arbitrary NAS shares. Check the identity, the share and the data before permitting writes. The old cluster must not be writing the same volume. Document the required PVC names, annotations, ZFS properties and snapshot metadata from the pinned release. Never rely on an ordinary PVC matching its old data by name without the adoption mechanism.
- [ ] **Backups and restore.** Backrest on TrueNAS covers the new datasets under the CSI parent and its exclusions for both applications. Check the source mount of each child dataset, the contents in B2 and an actual restore to new storage, independently of the original dataset and its snapshots. Restore the application files and the corresponding database backup together, in isolation, and start the application against them.

### Recovery decisions

- The NAS backs up its own datasets, independent of the cluster ([backups](../backups/README.md#nas-data-backrest-on-truenas)): Backrest and B2. No VolSync component on the bulk-data PVCs. The current VolSync setup uses LINSTOR snapshots and `replicated-temporary` volumes, not the NFS class.
- Check the backup plans when Immich and Nextcloud move: documents and photos are not disposable, even if thumbnails, previews and encoded videos are excluded. If a dataset name changes on adoption or restore, the backup source must follow it.
- ZFS snapshots protect against some local mistakes, not the loss of the NAS. Scheduling and retention of periodic snapshots on the NAS to decide; the CSI snapshots serve Kubernetes restore and clone workflows. A snapshot of the files alone does not make a consistent backup of the database and files. Coordinate the application and CNPG recovery points ([roadmap](../roadmap.md#backups)).
- The fallback to `truenas-csi` changes the CSI driver name and volume handles. A change of StorageClass alone does not migrate an existing volume. Plan a controlled copy/restore or a documented import before using the fallback with real data.

### Done when

- [ ] **Decision.** TNS CSI passes the tests, or the official driver is evaluated with the same checks. No application migration until recovery and the external backup work.
- [ ] **Docs**, in the same commit as the second NFS roadmap item: [storage](README.md) (decisions, status and diagram), [bootstrap](bootstrap.md) (the checks), [runbook](runbook.md) (permissions, lifecycle, adoption and recovery), [evaluations](evaluations.md) (the drivers set aside, the remaining open points), [backups](../backups/README.md) and its procedures (the new datasets), [observability](../observability/README.md), [reference](../reference.md), and the [conventions](../conventions.md#pod-security) where they need to distinguish an existing NAS share from a dynamic PVC. The [roadmap](../roadmap.md#storage) updated and ticked only once done. This plan removed after the last step.
