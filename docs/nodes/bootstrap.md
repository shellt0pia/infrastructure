# Nodes: first installation

Preparing the machines and booting them on the Talos ISO, then checking each node once the cluster is bootstrapped. Architecture: [README.md](README.md). The order of the whole bootstrap is in [first-bootstrap.md](../first-bootstrap.md): the BIOS and the image come first, the first boot comes after the [network](../network/bootstrap.md) is ready, the checks come after `just bootstrap cluster`.

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kubecluster-01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | The machines, with their SATA and NVMe SSDs installed. | [Hardware table](README.md#hardware) | kube-01 and kube-03: done. kube-02: [later](runbook.md#adding-kube-02) |
| 2 | Workstation tools (`just`, `talosctl`, `curl`). | [first-bootstrap.md](../first-bootstrap.md#phase-0--workstation) | Done |
| 3 | DHCP mappings and DNS records of the nodes, so that they are reachable by name from maintenance mode on. | [network/bootstrap.md](../network/bootstrap.md) | Done for kube-01 and kube-03 |

## 1. Hardware and BIOS

On each node:

- [x] **BIOS update.** Update the BIOS **first**. The disk encryption key is not bound to the firmware measurements, so later updates are fine too, but some firmware updates restore the factory Secure Boot keys (see below).
- [x] **UEFI.** UEFI only, CSM disabled (already done).
- [x] **TPM.** TPM 2.0 (Intel PTT) enabled and activated.
- [x] **Power.** *AC power recovery* set to *Power On*, *Wake-on-LAN* set to *LAN only* (already done).
- [x] **Boot order.** Put the **internal SATA disk first**. Boot from the USB drive with the one-time boot menu (F12), otherwise the node reboots on the ISO after the installation.
- [x] **Secure Boot: enabled, firmware in setup mode.** On the Dell BIOS: *Secure Boot → Secure Boot Enable*, then *Expert Key Management → Enable Custom Mode* and *Delete All Keys* (the exact wording depends on the BIOS version). In setup mode the firmware accepts new keys without authentication.
- [x] **Watchdog.** Check whether the machine has a hardware watchdog at the [first boot](#3-first-boot-in-maintenance-mode):

  ```sh
  talosctl --nodes kube-0X.shelltopia.net --insecure ls /sys/class/watchdog
  ```

  Expected: `watchdog0`. kube-02 has two under Fedora CoreOS (`intel_oc_wdt` and very likely `iTCO_wdt`), but the Talos kernel only ships `iTCO_wdt` and `wdat_wdt`, so `watchdog0` is the PCH TCO watchdog used by `talos/patches/watchdog.yaml`. If a node has no `watchdog0`, Talos logs an error and the rest of the configuration still applies.

The Talos ISO enrolls the Sidero Labs keys automatically **without the Microsoft certificates**: see [Secure Boot and encryption](README.md#secure-boot-and-encryption).

## 2. Talos image

- [x] **Image Factory.** Check that it responds:

  ```sh
  just talos schematic-id
  ```

- [x] **Download.** The ISO is `talos/talos-<version>-<schematic ID prefix>-amd64-secureboot.iso` (ignored by Git):

  ```sh
  just talos download-image
  ```

- [x] **USB drive.** Write the ISO to a USB drive, with Fedora Media Writer or `dd`.

A single USB drive should be enough: Talos runs from RAM once booted, so the nodes can be booted one after the other by removing the drive in between. If a node does not cope with the drive being removed, boot it from the drive again.

## 3. First boot in maintenance mode

- [x] **Enrollment.** Boot each node from the USB drive, with the firmware in setup mode. systemd-boot enrolls the Sidero Labs keys and reboots the machine (a countdown is shown on the console).
- [x] **Maintenance mode.** Boot from the USB drive again (F12): Talos starts in maintenance mode, the console shows the addresses obtained through DHCP and SLAAC.

From the workstation, using the names created in the [network setup](../network/bootstrap.md#2-dns-unbound-internal-only). If a name does not answer, use the IPv4 address shown on the console and check the DHCP mapping, the router advertisements and the DNS record.

- [x] **Secure Boot:**

  ```sh
  talosctl get securitystate --insecure --nodes kube-0X.shelltopia.net
  ```

  Expected: `SECUREBOOT` is `true`. Otherwise, check the BIOS: the TPM disk encryption refuses to enroll without Secure Boot (`checkSecurebootStatusOnEnroll`), so the installation would fail.

- [x] **Disks:**

  ```sh
  talosctl get disks --insecure --nodes kube-0X.shelltopia.net
  ```

  Expected: the WWID of the SATA SSD and the serial of the NVMe SSD match the [hardware table](README.md#hardware). Fill the missing ones in the table and in `talos/nodes/kube-0X.yaml`. The NVMe SSD is entirely repartitioned by Talos at install: make sure it holds nothing worth keeping.

- [x] **Network interface:**

  ```sh
  talosctl get links --insecure --nodes kube-0X.shelltopia.net
  ```

  Expected: the `HW ADDR` of the physical interface matches the MAC address of the table, used by the `LinkAliasConfig` of the node file.

- [x] **Addresses:**

  ```sh
  talosctl get addresses --insecure --nodes kube-0X.shelltopia.net
  ```

  Expected: the reserved IPv4 address, the ULA address of the [network](../network/README.md#nodes-subnet) and a GUA address with the same interface identifier.

- [x] **USB drive.** Remove it once every node is booted in maintenance mode, then [bootstrap the cluster](../cluster/bootstrap.md#3-bootstrap).

## 4. Checks after the bootstrap

On each node, once `just bootstrap cluster` has completed:

- [x] **Health and Secure Boot:**

  ```sh
  talosctl health
  talosctl get securitystate
  ```

  Expected: the node is healthy, Secure Boot is enabled.

- [x] **Volumes:**

  ```sh
  talosctl get volumestatus
  talosctl get volumestatus r-storage -o yaml
  talosctl ls -l /dev/mapper
  ```

  Expected: `STATE`, `EPHEMERAL` and `r-storage` are `ready` and encrypted (`luks2`). The `r-storage` partition spans the whole NVMe SSD, and `mountLocation` is the decrypted device (`/dev/dm-N`). The stable name used by LINSTOR is the `/dev/mapper/luks2-r-storage` link to it.

- [x] **Extensions:**

  ```sh
  talosctl get extensions
  ```

  Expected: `drbd`, `i915`, `intel-ucode`, `nfsrahead`, `nut-client` and `realtek-firmware`.

- [x] **NUT:**

  ```sh
  talosctl service ext-nut-client
  talosctl logs ext-nut-client
  ```

  Expected: the service is running, and the logs show the connection to the UPS.

- [x] **Addresses:**

  ```sh
  talosctl get addresses
  ```

  Expected: the IPv4, ULA and GUA addresses. The IPv6 ones end with the EUI-64 identifier (`…ff:fe…`).

- [x] **Router advertisements.** Find the kernel name of the `lan0` link, then read its `accept_ra`:

  ```sh
  talosctl get links
  talosctl read /proc/sys/net/ipv6/conf/<link>/accept_ra
  ```

  Expected: `2` (router advertisements accepted even with forwarding enabled). With `1`, the GUA/ULA addresses would disappear once forwarding is enabled by the CNI.

- [x] **Image verification:**

  ```sh
  talosctl image ls --namespace system
  ```

  Expected: the images have the `talos.dev/verified` label.

- [x] **Time:**

  ```sh
  talosctl get timeservers
  talosctl time
  ```

  Expected: `ntp-01.shelltopia.net`, then synchronized.

- [x] **etcd:**

  ```sh
  talosctl etcd members
  ```

  Expected: the peer URLs are the IPv4 and ULA addresses.

- [x] **Watchdog:**

  ```sh
  talosctl get watchdogtimerstatus
  ```

  Expected: the watchdog is armed.

- [x] **Scheduler:**

  ```sh
  talosctl read /system/config/kubernetes/kube-scheduler/scheduler-config.yaml
  ```

  Expected: the `ImageLocality` plugin is disabled and `PodTopologySpread` has the default constraints.

- [x] **Kubelet:**

  ```sh
  kubectl get --raw /api/v1/nodes/kube-01/proxy/configz | jq .kubeletconfig
  ```

  Expected: `shutdownGracePeriod` is `1m30s`, `serializeImagePulls` is `false` and `crashLoopBackOff.maxContainerRestartPeriod` is `1m0s`.

To start over from scratch, see [starting over](runbook.md#starting-over).
