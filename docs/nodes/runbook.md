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

## Power outage

The NAS runs the NUT server that watches the UPS (`ups` in `talos/vars.yaml`), and every node runs the NUT client extension (`talos/patches/extensions.yaml.j2`): when the UPS goes on battery, the nodes shut down 90 s later with `/sbin/poweroff` ([decisions](README.md#decisions)). They all go down together, so the whole cluster stops: there is no quorum left for etcd nor for the DRBD volumes. The BIOS is set to *Power On* after a power loss, so the nodes boot again by themselves when the power is back ([BIOS checklist](bootstrap.md#1-hardware-and-bios)).

Not tested yet with a real outage.

- [ ] **Network and NAS first.** The nodes configure their network dynamically (DHCPv4, router advertisements) and get their time and names from OPNsense, and the applications need the NAS for their NFS volumes. Check that both are back before the nodes, so that they find their network and their volumes as soon as they boot.
- [ ] **Power the nodes on** that did not boot by themselves (*Wake-on-LAN* is set to *LAN only*). Keep a console at hand: a [TPM unlock failure](evaluations.md#open-points) needs a cold power cycle.
- [ ] **Checks**, once the nodes are back:

  ```sh
  talosctl etcd members
  kubectl get nodes
  flux get ks -A
  kubectl linstor node list
  kubectl linstor resource list
  ```

  Expected: every node a member of etcd and `Ready`, every Kustomization `Ready`, every LINSTOR node `Online`. The replicas are `Outdated` then `UpToDate` once DRBD has resynchronized ([checking the state](../storage/runbook.md#checking-the-state)).

- [ ] **BGP.** On OPNsense, the sessions with the nodes are `Established` again:

  ```sh
  vtysh -c 'show bgp summary'
  ```

## Shutting the cluster down on purpose

Before a power maintenance, for instance. Not tested yet.

- [ ] **Node by node**, while the Kubernetes API answers. The recipe cordons and drains the node first:

  ```sh
  just talos shutdown-node kube-0X
  ```

- [ ] **The last nodes.** Once etcd has lost its quorum, the API is down and the nodes can no longer be drained: skip the cordon and the drain.

  ```sh
  just talos shutdown-node kube-0X --force
  ```

Then start again as after a [power outage](#power-outage).

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
