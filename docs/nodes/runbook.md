# Nodes: runbook

Day-to-day operations on the nodes. Architecture: [README.md](README.md).

## Adding kube-02

Once `home` has been migrated to the cluster:

- [ ] **Hardware.** Install the SATA SSD, then follow the [BIOS checklist](bootstrap.md#1-hardware-and-bios) for this machine.
- [ ] **Network.** Remove the DHCP mapping and DNS records of `home`, then create those of kube-02 ([network](../network/bootstrap.md)).
- [ ] **First boot.** Boot it in [maintenance mode](bootstrap.md#3-first-boot-in-maintenance-mode).
- [ ] **Configuration.** Fill the WWID of the SATA SSD and the serial of the NVMe SSD in `talos/nodes/kube-02.yaml`, uncomment kube-02 in `talos/vars.yaml`.
- [ ] **Join.** The node joins etcd automatically:

  ```sh
  just talos talosconfig
  just talos apply-node kube-02 --insecure
  talosctl etcd members
  ```

  Expected: kube-02 is a member.

- [ ] **BGP.** Nothing to configure: the node opens its sessions and OPNsense accepts them through the listen ranges. Check on OPNsense:

  ```sh
  vtysh -c 'show bgp summary'
  ```

- [ ] **Storage.** The satellite of kube-02 creates its `nvme` pool on its own:

  ```sh
  kubectl linstor storage-pool list
  kubectl linstor resource list
  ```

  Expected: the pool of kube-02, and the existing `replicated` volumes with a diskless `TieBreaker` resource on the third node. Then run the [failover test](../storage/bootstrap.md#3-failover-test).

## Rebuilding a node

The disks are unlocked by the TPM as long as the machine boots a Talos image signed by Sidero Labs with Secure Boot enabled. Firmware updates, kernel arguments changes and Secure Boot database updates do not affect it. The unlocking fails if the TPM is cleared (BIOS reset of the PTT), the motherboard is replaced or Secure Boot is disabled. In that case, rebuild the node:

- [ ] **Remove the node.** From another node, remove it from etcd and from Kubernetes, then from LINSTOR (the operator keeps a deleted node registered by default, `deletionPolicy: Retain`, and its volumes will not exist on the wiped disk):

  ```sh
  talosctl --nodes <other> etcd remove-member kube-0X
  kubectl delete node kube-0X
  kubectl linstor node lost kube-0X                       # removes the node and its replicas from LINSTOR
  ```

- [ ] **Wipe the disks.** Boot the node from the ISO (re-enroll the keys if the firmware restored its defaults), then wipe both disks (not tested yet on this hardware):

  ```sh
  talosctl wipe disk sda nvme0n1 --insecure --nodes kube-0X.shelltopia.net
  ```

  The `r-storage` volume of the NVMe SSD cannot be unlocked anymore either: if it were kept, Talos would find the encrypted partition and fail to open it instead of recreating it.

- [ ] **Apply the configuration.** The data stored by the applications is replicated on the other nodes (CloudNativePG, DRBD replicas of the `replicated` class), the storage solution then rebuilds the replicas of this node:

  ```sh
  just talos apply-node kube-0X --insecure
  kubectl linstor resource list
  ```

  Expected: the `replicated` volumes are back to 2 replicas, otherwise [adjust the resource group](../storage/runbook.md#bringing-a-volume-back-to-2-replicas). The volumes of the `local` class of this node are lost: restore them from the backups ([backups](../backups/runbook.md)).

A node that stays stuck after a TPM unlock failure may only need a cold power cycle ([open points](evaluations.md#open-points)).

## Starting over

Put a node back in maintenance mode, then run the bootstrap again:

```sh
just talos reset-node kube-0X
just bootstrap cluster
```

The reset wipes `STATE`, `EPHEMERAL` and the `r-storage` raw volume of the NVMe SSD: its key is locked to `STATE` (`lockToState`), it could not be unlocked anymore anyway.

## Checking the NFS read-ahead

Once a NFS volume is mounted by a pod, check the read-ahead set by `nfsrahead`:

1. **Find the device number** of the mount (`0:NN`):

   ```sh
   talosctl read /proc/self/mountinfo
   ```

2. **Read its read-ahead:**

   ```sh
   talosctl read /sys/class/bdi/0:NN/read_ahead_kb
   ```

   Expected: `16000` (default embedded in the Talos v1.14 extension), or `16384` once the extension reads `/etc/nfs.conf` (`talos/patches/nfs.yaml`, [open points](evaluations.md#open-points)).
