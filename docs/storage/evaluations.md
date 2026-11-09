# Storage: evaluations and open points

The choices considered and set aside, and what is still to check or watch. The resulting architecture is in [README.md](README.md#decisions).

## Rejected options

| Option | Why not |
| --- | --- |
| Mayastor | Hugepages, dedicated CPU cores, NVMe-oF. Piraeus/LINSTOR replicates in the kernel, is light on CPU and RAM, offers CSI snapshots on LVM thin and automatic failover with the HA controller. |
| 3 replicas for the `replicated` class | Losing 2 nodes means a restore anyway, and every write would cross the single 1 Gb/s NIC twice. |
| TopoLVM | Only if the `local` class does not work out. |
| Volumes for the bulk data | Media, Immich library, Nextcloud data and mail/calendar archives stay on the NAS, mounted through static NFS PersistentVolumes (NFS 4.2, no csi-driver-nfs). |
| Inline `nfs` pod volumes | Forbidden by the `restricted` Pod Security profile ([cluster](../cluster/README.md#pod-security)). A static PersistentVolume per share and per namespace instead ([runbook](runbook.md#mounting-a-nas-share)). |
| csi-driver-nfs | One more component to run for shares that already exist: it provisions a directory per volume, the static PersistentVolumes mount the existing shares as they are. |
| A dedicated VLAN for DRBD, DRBD and LINSTOR TLS | The nodes subnet is trusted, DRBD runs over the node ULA addresses. |
| Piraeus module loader | Removed (`talos-loader-override`): the DRBD module comes from the `siderolabs/drbd` extension and is loaded by Talos. |

## Open points

| Topic | Notes |
| --- | --- |
| LINSTOR thin pool | LINSTOR allows overcommitting it by default. If volumes grow close to the NVMe size, set `MaxOversubscriptionRatio` on the `LinstorCluster` (and watch the thin pool data and metadata usage once the metrics stack is there). |
| Talos and the LINSTOR VG | Talos scans the LVM volumes at boot. Check that it does not activate or complain about the `linstor_nvme` thin pool (`talosctl dmesg`, `talosctl logs` after a reboot). |
| Piraeus on Talos | The `talos-loader-override` satellite configuration follows the Piraeus how-to (`docs/how-to/talos.md`). Compare it with the how-to after each operator upgrade. |
| Failover test | Once kube-02 has joined ([test](bootstrap.md#3-failover-test)). |
| Tie-breakers | Once kube-02 joins, check that the existing 2-replica volumes get their diskless tie-breaker ([adding kube-02](../nodes/runbook.md#adding-kube-02)). |
| NFS to the NAS | The NAS exports must allow the nodes subnet, check the [read-ahead](../nodes/runbook.md#checking-the-nfs-read-ahead). |
| SELinux labels of the volumes | The files of the LINSTOR volumes are `unlabeled_t`: every write of a pod (`pod_t`) is an AVC denial, allowed only because Talos runs SELinux in permissive mode (`permissive=1`). Seen on 2026-11-09 in the `auditd` logs of kube-03 (VictoriaLogs `log_source:talos-service "talos-service":auditd`): `VMSingle` and `VLSingle` on `drbd1000` and `drbd1003`, about 137 lines per second (7 audit records per denial), fed back by the writes of `VLSingle` itself. To fix before going enforcing, or the pods could not write to their volumes: whether the LINSTOR CSI driver supports mounting with the SELinux context of the pod (`seLinuxMount` in its `CSIDriver`), otherwise how Talos and containerd relabel the volumes, then the existing volumes. |
