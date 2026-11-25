# NFS storage

Temporary document: the plan of the two NFS items of the [Storage](../roadmap.md#storage) section of the roadmap, step by step, as in [cluster-tools](../cluster-tools.md). Each step writes its decisions in the topic documents and ticks its item of the roadmap in the same commit ([AGENTS.md](../../AGENTS.md#do-not)). This document is deleted after the last step.

## Steps

| Step | Roadmap items | Why in this order | Status |
| --- | --- | --- | --- |
| [1](#1-static-nfs-volumes) | Access to the existing shares of the NAS | Checks NFS, the network and the Talos mounts without a CSI driver. | To do |
| [2](#2-dynamic-nfs-volumes) | A CSI driver for the data of Immich and Nextcloud | Once the NFS path works: the driver adds the provisioning of the datasets and exports, not another storage backend. | TNS CSI accepted after available trial checks |
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

1. **Driver:** TNS CSI for a disposable trial, subject to the tests of [step 4](#4-validation-and-recovery). The kubectl plugin, inventory dashboards and adoption of retained volumes are the advantages over the official driver. Metrics alone are no longer a differentiator. The official driver is the fallback, not a second driver to deploy alongside TNS CSI.
2. **Protocol:** NFS only. Neither iSCSI, NVMe-oF nor SMB used; LINSTOR already provides the block storage. One ZFS dataset per PVC for quotas, snapshots and independent recovery, rather than the subdirectories of `csi-driver-nfs`.
3. **Class:** `truenas-nfs`, not default (`replicated` stays so), `Retain`, `Immediate`, expansion allowed, NFS 4.2 with hard mounts. `ReadWriteMany` where the application needs shared access; it does not make concurrent application writers safe. A separate `truenas-nfs` VolumeSnapshotClass, not default (`linstor` stays so), with `deletionPolicy: Retain` for manual snapshots. Its retention is a separate decision from that of the PVs.
4. **Datasets:** create `vault/workloads/kubernetes/tns.csi.io/nfs` on TrueNAS before deployment, inheriting encryption from the passphrase-protected `vault/workloads` root. Future `docker` or `proxmox-ve` siblings may share that root if they can wait for the same manual unlock; do not create them for the trial. The driver may create one child dataset and export per PVC. Use per-PVC quotas, with no additional quota on the parent. The driver and protocol components keep the tree distinct from existing shares and leave room for `vault/workloads/kubernetes/tns.csi.io/nvme-of` or `vault/workloads/kubernetes/csi.truenas.io/<protocol>` later. Do not create those branches now; the layout is not an authorization boundary or a migration mechanism. No static dataset/export per application. Start at `recordsize=128 KiB` for mixed file workloads; check the effective value on provisioned children. Tune a dedicated dataset only if measurements justify it. Inherit `compression=lz4` and set `exec=off` on the NFS parent: these datasets store application data, not executables. `exec=off` controls local execution on TrueNAS; it does not set `noexec` on the Talos NFS mounts. Check both properties on the disposable child dataset. Keep `sync` enabled and deduplication off. Check the quota and reservation behaviour rather than assuming that the PVC size reserves space. The names or ZFS metadata must let the NAS backup and recovery procedures map a dataset to its application.
5. **GitOps:** the OCI chart of TNS CSI (`oci://registry-1.docker.io/bfenski/tns-csi-driver`, [deployment](https://github.com/fenio/tns-csi/blob/main/docs/DEPLOYMENT.md)), through an `OCIRepository` and `HelmRelease`, not an imperative Helm install. Pin the version as in the [convention](../conventions.md#charts), Renovate follows it. Proposed namespace and application: `tns-csi/tns-csi`. The namespace is privileged for the node plugin (host mounts and mount propagation); the application namespaces stay `restricted`.
6. **Resources:** requests and memory limits of the [convention](../conventions.md#resources-and-priorities) for every container, no CPU limits. `system-node-critical` for the CSI node plugin; `system-cluster-critical` proposed for the controller as for the storage controllers. Check the defaults and sidecars in the render, then the usage in VictoriaMetrics and Goldilocks.
7. **Secrets:** a dedicated TrueNAS account and API key. Connect to `nas-01-dmz.shelltopia.net` through `wss://` and verify its Let's Encrypt certificate. The item `nas-01-tns-csi` proposed in the `kubernetes` vault, synced through an `ExternalSecret` and the `onepassword` ClusterSecretStore ([secrets](../conventions.md#secrets)). Never a key in Helm values or a command line. Verify the existing Secret fields of the chart, the API roles required, and whether the rights can be limited to the CSI datasets (do not assume a parent dataset is an API authorization boundary).
8. **Network:** API access from the CSI components that need it, by FQDN, not from the application pods. An egress policy as in the [convention](../conventions.md#network-policies) for pod-networked components; inspect `hostNetwork` and the host policy for the node plugin. NFS data traffic from the nodes to the NAS. The generated exports allow the nodes subnet only, not every host. API availability and NFS availability are different: the tests check both.

### StorageClass

Candidate manifest, not tested yet. The chart can also generate the class; use one source only. The values reflect the intended layout; verify the parameter names against the pinned release.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nfs
provisioner: tns.csi.io
parameters:
  protocol: nfs
  pool: vault
  parentDataset: workloads/kubernetes/tns.csi.io/nfs
  server: nas-01-dmz.shelltopia.net
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.2
  - hard
```

`parentDataset` is relative to the pool ([deployment](https://github.com/fenio/tns-csi/blob/main/docs/DEPLOYMENT.md)). The export restrictions, permissions and other ZFS properties are left out until checked against the pinned release. The optional `deleteStrategy: retain` is a driver-side safeguard, not a replacement for `reclaimPolicy: Retain`; decide after the lifecycle and adoption tests.

### Chart preflight

Selected [`tns-csi-driver` 0.23.0](https://github.com/fenio/tns-csi/releases/tag/v0.23.0) for the trial. `helm lint` and `helm template` succeeded locally; nothing was deployed.

- The controller and node both reference `url`, `api-key` and `username` in the existing Secret. Use `wss://nas-01-dmz.shelltopia.net:443/api/current` and include the account name to use `auth.login_ex`. Keep TLS verification enabled. The node uses `hostNetwork`; verify API reachability and restrict controller egress separately.
- Disable `node.iscsi.enabled` to omit the `/etc/iscsi` host mount on Talos. The rendered privileged node plugin has bidirectional propagation for the kubelet `pods` and `plugins` paths. The rendered `CSIDriver` declares `fsGroupPolicy: File`; this does not guarantee that kubelet can change ownership over NFS.
- The chart rendered one non-default NFS class and a controller ServiceMonitor. The candidate export allowlist uses the nodes' IPv6 ULA subnet; confirm the observed mount source. Enable the snapshotter, but supply the non-default `truenas-nfs` VolumeSnapshotClass separately so its name and `Retain` policy are explicit. The chart's dashboard defaults to TCP 2137 in this release.
- The [TrueNAS 25.10 API reference](https://api.truenas.com/v25.10/) documents method-level roles, including `DATASET_WRITE` for create/update, `DATASET_DELETE` for deletion, `SHARING_NFS_WRITE` for export creation/deletion, `SNAPSHOT_WRITE` for snapshots, and `FILESYSTEM_ATTRS_WRITE` for ACL writes. This is not a validated minimum role set for the driver. No dataset-scoped API restriction was identified in the published privilege schema. Use the built-in Sharing Administrator (`SHARING_ADMIN`) as the trial candidate, not Full Administrator. The published RBAC reference distinguishes method-level roles from assignable group roles; confirm the privilege in the installed UI and validate the account against disposable volumes. See [account setup](bootstrap.md#truenas-service-account-and-api-key).

### Technical questions

- **Permissions.** Use `65534:65534` as a test identity, not as a confirmed production identity. Rely on Kubernetes to control which workloads can mount each PVC. Separate NAS identities for Immich and Nextcloud are not required; with shared numeric IDs and `AUTH_SYS`, the NAS does not distinguish them. Test the intended ownership and export restrictions before migration. Check the NFS parameters of the pinned release, root squashing, ACLs, `fsGroupPolicy` and the actual owner seen in the pod. Do not give every client root access to make `chown` work. NFS `AUTH_SYS` trusts the client; network and server permissions matter more than the PVC access mode.
- **Talos.** Does the node plugin mount the kubelet directories with the propagation Talos needs? Check SELinux on the NFS mounts and the reads/writes under `restricted` before enforcing SELinux. Do not copy the `ephemeral_t` mount option of LINSTOR without checking NFS and its label support. Check the `nfsrahead` setup on the CSI mounts too.
- **Dataset layout.** Check whether PVC names or UUIDs are used and define the layout of the Zerobyte volumes. Do not assume that a newly created child ZFS dataset is included in the existing parent mount of the Zerobyte container ([nas](../nas/README.md#backups-zerobyte)).
- **Secrets and TLS.** Verify certificate trust from the driver, minimum API roles and any dataset scoping supported by TrueNAS 25.10.8, and rotation without dropping mounts; check whether the plugin needs to read the driver Secret. No access for `kubernetes_viewers` to that Secret.
- **Retention.** How to rebind a retained PV in the same cluster, adopt it in a rebuilt cluster, and explicitly retire a dataset after a backup. What happens to its export and its snapshots at each step? A released PV is not a free volume. No automatic orphan cleanup.

### Plan

- [ ] **NAS**, by the user: the parent dataset, NFS service, API account and key in 1Password, with the permissions and the TLS certificate decided above.
- [x] **Render.** Select the chart release, read its values and changelog. Render the NFS-only configuration: Secret reference, StorageClass, controller and node plugin (host paths, propagation, privileges, RBAC, priority classes, resources and metrics). No other protocol classes and no extra default class.
- [x] **Manifests.** The Flux application, namespace, `ExternalSecret`, dependencies on `external-secrets-stores` and the Prometheus CRDs when the monitors are enabled, and the policy. The StorageClass and VolumeSnapshotClass, either from the chart or manifests of the app. Local checks: `flux build`, `helm template`, kubeconform. The HelmRelease is suspended in Git pending the [NAS prerequisites](bootstrap.md#7-dynamic-nfs-trial). Local schema validation passed for all 20 rendered resources. No direct apply to the cluster.
- [ ] **Deploy and check.** The Kustomization and HelmRelease `Ready`, controller available, CSI node pod and registration on each node, `tns.csi.io` registered, both new classes non-default. The `replicated` and `linstor` defaults unchanged. Before application PVCs, [step 3](#3-monitoring-and-administration) and [step 4](#4-validation-and-recovery).

## 3. Monitoring and administration

### Today

The cluster runs VictoriaMetrics (`VMAgent`, `VMSingle`, `VMAlert`), not kube-prometheus-stack. The operator converts the `ServiceMonitor` and `PodMonitor` CRDs, and `VMAgent` selects monitors of every namespace. Grafana is its own release in `observability`; its sidecars read ConfigMaps there, with `grafana_dashboard: "1"` and Prometheus data source UID `VictoriaMetrics` ([observability](../observability/README.md)). Do not widen their rights to Secrets or all namespaces for one dashboard.

### Upstream

- [TNS CSI](https://github.com/fenio/tns-csi): `controller.dashboard.enabled: true`, port 2137 by default in chart 0.23.0, for the in-cluster inventory. The kubectl plugin also starts a local dashboard (`kubectl tns-csi dashboard`, port 2137).
- `grafana.dashboards.enabled: true` creates a dashboard ConfigMap. The deployment guide describes discovery by kube-prometheus-stack; here check the namespace, labels and data source references first.
- The kubectl plugin (`kubectl krew install tns-csi`) includes `summary`, `list`, `list-snapshots`, `health`, `troubleshoot <pvc>` and `dashboard`. It can discover the credentials of the driver. It also has destructive commands (`cleanup`); not used as part of normal operations.

### Answers

1. **Metrics:** enable the endpoint and the ServiceMonitor of the chart. Check its coverage of the controller, node plugin and sidecars, and whether a host port is exposed (port conflicts and the host policy). The existing scraper and converted monitors do the work, no other Prometheus instance. Monitor API health, operation errors and latency, missing scrape targets, failed provisioning and capacity where exported. The pool capacity and disks still need monitoring of TrueNAS itself ([external devices](../observability/README.md#external-devices)).
2. **Grafana:** use the dashboard vendored from chart 0.23.0 next to the Grafana release, with data source `VictoriaMetrics`. Do not grant more RBAC to Grafana. Check the queries on VictoriaMetrics, and disable Flux substitution on its ConfigMap when it contains Grafana variables.
3. **Inventory:** the controller dashboard and its read APIs are routed only on the internal Gateway with administrator OIDC. Check login and the API after deployment. The UI is not a substitute for the access checks of Kubernetes ([OIDC](../cluster/README.md#oidc-authentication)).
4. **CLI:** the plugin on the workstation (pinned GitHub release in mise). Use the read-only commands for inventory and troubleshooting. Check its RBAC and how it obtains its TrueNAS credentials; a Kubernetes viewer must not gain NAS write rights by running it. No cleanup or adoption without an explicit recovery procedure.

### Plan

- [ ] **Metrics.** The monitor selected by `VMAgent`, the metrics in VictoriaMetrics, tested through the API outage of step 4; alert rules next to the application, tuned as in [alerting](../observability/README.md#alerting). Include a capacity alert or use the NAS metrics if the driver does not expose the needed series.
- [ ] **Grafana.** The dashboard discovered in `observability`, queries populated and data source selected. Review its panels after the first provisioning and the first failed operation.
- [ ] **Inventory.** Port-forward the dashboard Service and check the volume, its PVC, snapshots and health. Install the plugin on the workstation, check the same inventory and its permissions with the OIDC identities.
- [ ] **Docs.** The tools and rules in [observability](../observability/README.md), the commands in [runbook](runbook.md), the names, ports and 1Password item in [reference](../reference.md) once decided.

## 4. Validation and recovery

*Not tested yet.* All the tests use disposable datasets and volumes, never the data of Immich or Nextcloud. The destructive parts are performed by the user, separately from the read-only checks ([AGENTS.md](../../AGENTS.md#commands)).

### Checks

Use a fresh `nfs-trial` namespace and run the steps in order. The imperative commands below are for the user and disposable objects only. For a Git-managed trial, make equivalent changes in Git instead. Replace angle-bracket placeholders with values recorded during the trial. Stop if an object already exists or points outside the trial.

- [x] **Preflight and provision.** Check the driver and defaults first:

  ```sh
  kubectl config current-context
  flux get ks -n tns-csi
  flux get hr -n tns-csi
  kubectl -n tns-csi get deploy,ds,pods -o wide
  kubectl get csidriver tns.csi.io
  kubectl get csinode -o custom-columns='NODE:.metadata.name,DRIVERS:.spec.drivers[*].name'
  kubectl get storageclass,volumesnapshotclass
  kubectl get namespace nfs-trial
  ```

  Expected: the controller and all node agents are ready, `tns.csi.io` is registered on each node, `replicated` and `linstor` are still the defaults, and `nfs-trial` is `NotFound`.

  ```sh
  kubectl create namespace nfs-trial
  kubectl label namespace nfs-trial pod-security.kubernetes.io/enforce=restricted
  kubectl -n nfs-trial create -f - <<'EOF'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: data
  spec:
    storageClassName: truenas-nfs
    accessModes: [ReadWriteMany]
    resources:
      requests:
        storage: 1Gi
  EOF
  kubectl -n nfs-trial wait --for=jsonpath='{.status.phase}'=Bound pvc/data --timeout=5m
  kubectl -n nfs-trial get pvc data -o wide
  kubectl get pv <source-pv> -o yaml
  ```

  Expected: `Bound` before any pod exists, `spec.csi.driver: tns.csi.io`, `Retain`, and one new dataset and export in TrueNAS. Record the PV, volume handle, exact dataset and export path; check that the export allows only the configured node ULA subnet. On TrueNAS, check the effective properties:

  ```sh
  zfs get encryptionroot,keystatus,recordsize,compression,exec,refquota <source-dataset>
  ```

  Expected: `vault/workloads` is the available encryption root, `128K`, `lz4`, `off`, and a `1G` reference quota.

- [x] **Restricted pods and RWX.** Save this manifest as `.scratch/nfs-trial-pod.yaml`. The required anti-affinity puts the second pod on another node; if there is only one eligible node, leave this check pending.

  ```yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: writer
    labels:
      app: nfs-trial
  spec:
    automountServiceAccountToken: false
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      runAsGroup: 65534
      seccompProfile:
        type: RuntimeDefault
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: nfs-trial
            topologyKey: kubernetes.io/hostname
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
          requests: {cpu: 10m, memory: 16Mi}
          ## dd test below needs a lot of memory
          limits: {memory: 2048Mi}
        volumeMounts:
          - name: data
            mountPath: /data
    volumes:
      - name: data
        persistentVolumeClaim:
          claimName: data
  ```

  ```sh
  kubectl -n nfs-trial create -f .scratch/nfs-trial-pod.yaml
  yq '.metadata.name = "peer"' .scratch/nfs-trial-pod.yaml | kubectl -n nfs-trial create -f -
  kubectl -n nfs-trial wait --for=condition=Ready pod/writer pod/peer --timeout=5m
  kubectl -n nfs-trial get pods -o wide
  kubectl -n nfs-trial exec writer -- sh -ceu 'id; ls -ldn /data; umask 022; echo nfs-trial > /data/tmp; mv /data/tmp /data/probe; touch /data/remove-me; rm /data/remove-me; sha256sum /data/probe'
  kubectl -n nfs-trial exec peer -- sha256sum /data/probe
  kubectl -n nfs-trial exec writer -- grep ' /data ' /proc/mounts
  talosctl -n <writer-node> read /proc/mounts | grep -F '<export-path>'
  ```

  Expected: matching checksums on different nodes, `vers=4.2`, `hard`, and the expected NAS export. Record the checksum. Confirm the mount source on TrueNAS and follow the [read-ahead check](../nodes/runbook.md#checking-the-nfs-read-ahead). Check for SELinux denials on the mounting node (`talosctl -n <writer-node> dmesg` and VictoriaLogs). If writes fail, inspect ownership, ACLs, export mappings and SELinux before changing anything. Repeat with the application identities once known; do not assume `fsGroup` fixes NAS ownership or use `hostUsers: false`.

  Observed: both pods mounted the volume on different nodes, but the new dataset root was `0:0` with mode `0755`; UID `65534` could not write. TNS CSI 0.23.0 does not set the owner of the NFS dataset root at creation. For this empty trial dataset only, set its root owner and group to `65534:65534` on TrueNAS (not recursively), then repeat the write and checksum checks without recreating the PVC. Check the effective ACL if the write is still denied. Before production, define how dataset ownership is initialized for every new PVC and review the driver's root mapping on generated exports.

- [x] **Quota and expansion.** Use random input so compression cannot turn the fill test into a sparse or highly compressed file. Check pool headroom first and do not run against another mount:

  ```sh
  kubectl -n nfs-trial exec writer -- grep ' /data ' /proc/mounts
  kubectl -n nfs-trial exec writer -- df -k /data
  kubectl -n nfs-trial exec writer -- dd if=/dev/urandom of=/data/quota-test bs=1048576 count=1152
  kubectl -n nfs-trial exec writer -- rm -f /data/quota-test
  kubectl -n nfs-trial patch pvc data --type merge -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
  kubectl -n nfs-trial wait --for=jsonpath='{.status.capacity.storage}'=2Gi pvc/data --timeout=5m
  kubectl -n nfs-trial exec writer -- df -k /data
  kubectl -n nfs-trial exec writer -- sha256sum /data/probe
  ```

  Expected: `dd` fails at the quota with a quota or space error, not a network or permission error. After expansion, `zfs get refquota <source-dataset>` on TrueNAS shows `2G`, `df` shows more usable space, and the checksum is unchanged. If the fill succeeds, stop and investigate the quota before continuing.

- [x] **Snapshot, restore and clone.** Stop both test pods first so the source is quiescent. Keep it quiescent until both copies bind.

  Trial finding: TrueNAS returned `EACCES` on `pool.snapshot.create`. The method requires `SNAPSHOT_WRITE`, which `SHARING_ADMIN` does not include. The built-in `REPLICATION_ADMIN` includes it but also grants NAS-wide snapshot and replication rights and keychain credential management. Decide whether that scope is acceptable before adding the role. Otherwise leave CSI snapshot and restore unvalidated and continue testing Zerobyte and NAS-managed snapshots separately.

  ```sh
  kubectl -n nfs-trial delete pod writer peer
  kubectl -n nfs-trial create -f - <<'EOF'
  apiVersion: snapshot.storage.k8s.io/v1
  kind: VolumeSnapshot
  metadata:
    name: data-snap
  spec:
    volumeSnapshotClassName: truenas-nfs
    source:
      persistentVolumeClaimName: data
  EOF
  kubectl -n nfs-trial wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/data-snap --timeout=5m
  kubectl -n nfs-trial get volumesnapshot data-snap -o yaml
  kubectl get volumesnapshotcontent <snapshot-content> -o yaml
  kubectl -n nfs-trial create -f - <<'EOF'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: restored
  spec:
    storageClassName: truenas-nfs
    accessModes: [ReadWriteMany]
    resources:
      requests: {storage: 2Gi}
    dataSource:
      apiGroup: snapshot.storage.k8s.io
      kind: VolumeSnapshot
      name: data-snap
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: cloned
  spec:
    storageClassName: truenas-nfs
    accessModes: [ReadWriteMany]
    resources:
      requests: {storage: 2Gi}
    dataSource:
      kind: PersistentVolumeClaim
      name: data
  EOF
  kubectl -n nfs-trial wait --for=jsonpath='{.status.phase}'=Bound pvc/restored pvc/cloned --timeout=10m
  for copy in restored cloned; do
    COPY="$copy" yq '.metadata.name = strenv(COPY) | del(.spec.affinity) | .spec.volumes[0].persistentVolumeClaim.claimName = strenv(COPY) | .spec.containers[0].volumeMounts[0].readOnly = true' .scratch/nfs-trial-pod.yaml | kubectl -n nfs-trial create -f -
    kubectl -n nfs-trial wait --for=condition=Ready "pod/$copy" --timeout=5m
    kubectl -n nfs-trial exec "$copy" -- sha256sum /data/probe
  done
  kubectl -n nfs-trial delete volumesnapshot data-snap
  kubectl get volumesnapshotcontent <snapshot-content>
  kubectl -n nfs-trial get pvc data restored cloned
  ```

  Expected: two new PVs with distinct handles, both checksums match, and deleting the Kubernetes snapshot leaves the retained content and the backend snapshot. Record the backend snapshot and any clone dependencies for cleanup. The three PVCs remain bound.

- [x] **API-only interruption.** Use a maintenance window. Restart the `writer` from the saved manifest, verify the mount, then deny only controller egress to the NAS API. This works even on the same subnet, because Cilium applies the rule at the pod. Leave DNS, node agents and NFS TCP 2049 alone. Confirm the NAS AAAA address first and adjust the `/128` if it has changed. Keep the delete command ready; do not commit the temporary policy.

  ```sh
  kubectl -n nfs-trial create -f .scratch/nfs-trial-pod.yaml
  kubectl -n nfs-trial wait --for=condition=Ready pod/writer --timeout=5m
  kubectl -n tns-csi create -f - <<'EOF'
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: tns-csi-trial-deny-nas-api
  spec:
    endpointSelector:
      matchLabels:
        app.kubernetes.io/name: tns-csi-driver
        app.kubernetes.io/component: controller
    egressDeny:
      - toCIDR:
          # Cilium deny rules do not support toFQDNs; use the current NAS AAAA.
          - fd38:4c4d:8f66:f::a/128
        toPorts:
          - ports:
              - port: "443"
                protocol: TCP
  EOF
  # Confirm the API traffic is dropped in Hubble. If needed, restart only
  # the controller to force a fresh WebSocket connection; do not wait for Ready.
  # kubectl -n tns-csi rollout restart deploy/tns-csi-controller
  # After the API block is in place:
  kubectl -n nfs-trial exec writer -- sh -ceu 'echo api-outage > /data/api-probe; cat /data/api-probe; sha256sum /data/probe'
  kubectl -n nfs-trial create -f - <<'EOF'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: api-outage
  spec:
    storageClassName: truenas-nfs
    accessModes: [ReadWriteMany]
    resources:
      requests: {storage: 1Gi}
  EOF
  kubectl -n nfs-trial describe pvc api-outage
  kubectl -n tns-csi logs deploy/tns-csi-controller -c tns-csi-plugin --since=10m
  kubectl -n tns-csi delete ciliumnetworkpolicy tns-csi-trial-deny-nas-api
  kubectl -n nfs-trial wait --for=jsonpath='{.status.phase}'=Bound pvc/api-outage --timeout=10m
  kubectl -n nfs-trial get pvc api-outage -o wide
  ```

  Expected: mounted I/O succeeds while the new PVC remains pending or retries. In VictoriaMetrics, check the controller target and provisioning errors; check `TNSCSITrueNASDisconnected` if the target stays up and reports a disconnected WebSocket for five minutes. A controller that fails to start is not covered by that gauge alert. After rollback, one dataset and export exist for the new claim. If the claim bound during the block, the API interruption was not demonstrated.

- [x] **Restart and reconnect.** Run separately from the outage, with no active provisioning or restoration. Confirm quorum before scheduling a node reboot; skip it on the two-node cluster. A normal controller rollout is not an NFS outage test.

  ```sh
  kubectl -n tns-csi rollout restart deployment/tns-csi-controller
  kubectl -n tns-csi rollout status deployment/tns-csi-controller --timeout=5m
  kubectl -n tns-csi rollout restart daemonset/tns-csi-node
  kubectl -n tns-csi rollout status daemonset/tns-csi-node --timeout=5m
  kubectl -n nfs-trial exec writer -- sha256sum /data/probe
  # Move the test writer without draining a production node:
  kubectl -n nfs-trial delete pod writer
  yq '.spec.nodeSelector."kubernetes.io/hostname" = "<other-node>"' .scratch/nfs-trial-pod.yaml | kubectl -n nfs-trial create -f -
  kubectl -n nfs-trial wait --for=condition=Ready pod/writer --timeout=5m
  kubectl -n nfs-trial get pod writer -o wide
  kubectl -n nfs-trial exec writer -- sha256sum /data/probe
  ```

  Expected: the checksum matches after each restart and on the other node. In an agreed window when quorum can tolerate it, reboot a node with `talosctl -n <node> reboot` and repeat the readiness and checksum checks. Rehearse a chart upgrade through Git with the PVC mounted, then repeat them again; check TrueNAS for duplicate exports and Talos for stale mounts. Defer a full NAS reboot unless needed. If tested, unlock `vault/workloads` after boot and verify I/O on the existing hard mount resumes before recreating pods. I/O may block during that outage.

- [x] **Retention and same-cluster rebind.** Use the recorded source PV only. Confirm `Retain` before removing the claim, and confirm the PV is `Released` with the old claim UID before replacing its claim reference.

  ```sh
  kubectl get pv <source-pv> -o yaml
  kubectl -n nfs-trial delete pod writer
  kubectl -n nfs-trial delete pvc data
  kubectl get pv <source-pv> -o wide
  kubectl patch pv <source-pv> --type json -p '[{"op":"replace","path":"/spec/claimRef","value":{"namespace":"nfs-trial","name":"data"}}]'
  kubectl -n nfs-trial create -f - <<'EOF'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: data
  spec:
    volumeName: <source-pv>
    storageClassName: truenas-nfs
    accessModes: [ReadWriteMany]
    resources:
      requests: {storage: 2Gi}
  EOF
  kubectl -n nfs-trial wait --for=jsonpath='{.status.phase}'=Bound pvc/data --timeout=5m
  kubectl -n nfs-trial create -f .scratch/nfs-trial-pod.yaml
  kubectl -n nfs-trial wait --for=condition=Ready pod/writer --timeout=5m
  kubectl -n nfs-trial exec writer -- sha256sum /data/probe
  ```

  Expected: TrueNAS retains the original dataset, export and snapshots; the replacement PVC binds the same PV and reads the original checksum. Do not use a plain PVC without `volumeName` for this rebind.

- [ ] **Adoption after cluster loss.** Use a separate recovery cluster with the pinned driver, snapshot CRDs and a restricted `nfs-trial` namespace. Stop all source writers and prevent the old cluster from using the test export during the rehearsal. Use an administrator for the plugin; do not expose its TrueNAS credentials to viewers. Follow the [pinned adoption guide](https://github.com/fenio/tns-csi/blob/v0.23.0/docs/ADOPTION.md) and inspect the output before applying:

  ```sh
  kubectl --context <recovery-context> tns-csi adopt <source-dataset> --pvc-name data --namespace nfs-trial -o yaml > .scratch/nfs-trial-adopt.yaml
  kubectl --context <recovery-context> apply --dry-run=server -f .scratch/nfs-trial-adopt.yaml
  kubectl --context <recovery-context> apply -f .scratch/nfs-trial-adopt.yaml
  kubectl --context <recovery-context> -n nfs-trial wait --for=jsonpath='{.status.phase}'=Bound pvc/data --timeout=5m
  yq '.spec.containers[0].volumeMounts[0].readOnly = true' .scratch/nfs-trial-pod.yaml | kubectl --context <recovery-context> -n nfs-trial create -f -
  kubectl --context <recovery-context> -n nfs-trial wait --for=condition=Ready pod/writer --timeout=5m
  kubectl --context <recovery-context> -n nfs-trial exec writer -- sha256sum /data/probe
  ```

  Expected: the generated PV has `Retain` and references the recorded driver, handle and export, and the PVC explicitly binds that PV. No new dataset is provisioned. Record the dataset's `tns-csi:*` properties (`zfs get all <source-dataset> | grep 'tns-csi:'` on TrueNAS) and the separately retained snapshot handles. Adoption of the volume does not by itself prove Kubernetes snapshot recovery. Remove the recovery pod and release its retained claim before enabling writes on the source again.

- [ ] **Zerobyte and restore.** With Zerobyte installed as in [backup bootstrap](../backups/bootstrap.md#3-nas-data-zerobyte), add the trial child dataset to a test volume and job using a read-only source mount. In the Zerobyte UI, run the job, browse the resulting B2 snapshot for `probe`, then restore to a distinct writable scratch dataset. On TrueNAS, compare the restored file with the recorded checksum:

  ```sh
  sha256sum /mnt/<scratch-dataset>/<restored-path>/probe
  ```

  Expected: the checksum matches without reading the original export or rolling back a ZFS snapshot. Verify that the recursive TrueNAS snapshot task also includes the new child and gives it the expected retention. Before real migration, repeat with the application backup jobs and exclusions; restore the corresponding CNPG backup and files into an isolated instance and check it can read the restored data. The disposable file test does not validate application consistency.

- [x] **Deliberate retirement.** After evidence and backups are recorded, inventory the trial PVs, snapshot content and NAS objects in both clusters. Remove only trial pods and claims; confirm each PV becomes `Released` and still has `Retain` before deleting its Kubernetes record.

  ```sh
  kubectl -n nfs-trial get pods,pvc -o wide
  kubectl -n nfs-trial delete pod writer restored cloned --ignore-not-found
  kubectl -n nfs-trial delete pvc data restored cloned api-outage
  kubectl get pv <source-pv> <restore-pv> <clone-pv> <outage-pv> -o wide
  kubectl get volumesnapshotcontent <snapshot-content> -o yaml
  ```

  If an earlier check was skipped, omit its absent objects. Verify no recovery pod still mounts an export. In TrueNAS, retire only the recorded test shares, snapshots and datasets. Inspect snapshot clones first (`zfs get clones <source-snapshot>`); retire dependent test copies before the origin snapshot, and never use recursive destruction to force it. With `Retain`, removing the Kubernetes records does not retire backend data:

  ```sh
  kubectl delete volumesnapshotcontent <snapshot-content>
  kubectl delete pv <source-pv> <restore-pv> <clone-pv> <outage-pv>
  kubectl -n nfs-trial get pods,pvc,volumesnapshot
  kubectl delete namespace nfs-trial
  ```

  Expected: no trial objects or exports remain, and the original parent, periodic snapshot task and existing shares are untouched. If testing driver-side `deleteStrategy`, use a separate disposable class and volume; this procedure tests Kubernetes `Retain`.

### Recovery decisions

- The NAS backs up its own datasets, independent of the cluster ([backups](../backups/README.md#nas-data-zerobyte-on-truenas)): Zerobyte and B2. No VolSync component on the bulk-data PVCs. The current VolSync setup uses LINSTOR snapshots and `replicated-temporary` volumes, not the NFS class.
- Check the backup jobs when Immich and Nextcloud move: documents and photos are not disposable, even if thumbnails, previews and encoded videos are excluded. If a dataset name changes on adoption or restore, the backup source must follow it.
- ZFS snapshots protect against some local mistakes, not the loss of the NAS. Configure a recursive TrueNAS periodic snapshot task under `vault/workloads/kubernetes/tns.csi.io/nfs`: hourly, retained for two weeks. Verify coverage of newly provisioned children and expiry. CSI snapshots serve Kubernetes restore and clone workflows and have a separate lifecycle. Zerobyte provides longer retention off the NAS. A snapshot of the files alone does not make a consistent backup of the database and files. Coordinate the application and CNPG recovery points ([roadmap](../roadmap.md#backups)).
- The fallback to `truenas-csi` changes the CSI driver name and volume handles. A change of StorageClass alone does not migrate an existing volume. Plan a controlled copy/restore or a documented import before using the fallback with real data.

### Done when

- [ ] **Decision.** TNS CSI passes the tests, or the official driver is evaluated with the same checks. No application migration until recovery and the external backup work.
- [ ] **Docs**, in the same commit as the second NFS roadmap item: [storage](README.md) (decisions, status and diagram), [bootstrap](bootstrap.md) (the checks), [runbook](runbook.md) (permissions, lifecycle, adoption and recovery), [evaluations](evaluations.md) (the drivers set aside, the remaining open points), [backups](../backups/README.md) and its procedures (the new datasets), [observability](../observability/README.md), [reference](../reference.md), and the [conventions](../conventions.md#pod-security) where they need to distinguish an existing NAS share from a dynamic PVC. The [roadmap](../roadmap.md#storage) updated and ticked only once done. This plan removed after the last step.
