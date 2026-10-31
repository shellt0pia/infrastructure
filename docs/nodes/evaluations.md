# Nodes: evaluations and open points

The choices considered and set aside, the studies still to do, and what is still to check or watch. The resulting configuration is in [README.md](README.md).

## Rejected options

| Option | Why not |
| --- | --- |
| talhelper | Unmaintained. |
| Omni, Cluster API, a Terraform provider for Talos | Not used: the machine configs are plain documents templated with minijinja, driven by the `just talos` recipes. |
| topf | Not adopted for now, see [secrets](../secrets/evaluations.md#replacing-the-talos-recipes-with-topf). |
| The Microsoft Secure Boot certificates | Enrolling only the Sidero Labs keys means the machine only boots images signed by Sidero Labs. The onboard devices are part of the firmware and need no option ROM ([Secure Boot](README.md#secure-boot-and-encryption)). |
| A Talos ingress firewall | OPNsense filters everything entering the nodes subnet, see [network](../network/evaluations.md#rejected-options). |

## Disk selectors

The SATA SSDs are selected by WWID because Talos v1.14 leaves the serial of SATA disks empty: it reads the serial from sysfs, where libata does not expose it, and its fallback (udev `ata_id`/`scsi_id` helpers) only runs for the `ata` and `scsi` transports, not for `sata` (AHCI controllers). The WWID is the WWN written in the drive by the manufacturer (`naa.5…`), as unique and stable as the serial.

The NVMe SSDs are selected by serial number, and the NIC by its permanent MAC address.

## Remote node management

Study a way to power cycle a node remotely and, ideally, to see its console without a working OS. A cold power cycle is the only fix found for the [TPM unlock failure](#open-points) seen once on kube-01, and with 3 nodes a stuck node should not need a trip to the rack.

- **Intel AMT**: power control and remote KVM out of band. Needs a vPro chipset and CPU (check in the MEBx, `Ctrl+P` at boot), on each node. Very privileged and on the same NIC as Talos: strong password in 1Password, TLS if possible, OPNsense rules so that only the admin workstation reaches the AMT ports (16992-16995, 664). Clients: MeshCommander, `amtterm`/`wsman`.
- **A smart plug** (local API, no cloud) per node with *AC Recovery: Power On* in the firmware: power only. Or a PiKVM-like device for the console.

Once chosen, document the procedure in the [runbook](runbook.md#rebuilding-a-node).

## Open points

| Topic | Notes |
| --- | --- |
| Watchdog | `watchdog0` exists and is armed on kube-01 and kube-03 under Talos ([BIOS checklist](bootstrap.md#1-hardware-and-bios)). |
| `nfsrahead` | siderolabs/extensions#1255 moves its configuration to `/etc/nfs.conf` (`talos/patches/nfs.yaml` is ready for it). Check the [read-ahead](runbook.md#checking-the-nfs-read-ahead). |
| Talos firmware updates | Announced by Sidero Labs: to use for the BIOS updates. The disk encryption is not bound to the firmware measurements. |
| Firmware reset to the factory Secure Boot keys | Some BIOS updates do it: enroll the Sidero Labs keys again before booting Talos. |
| SATA serial | Talos does not detect the serial of SATA disks behind AHCI controllers (transport `sata`). If fixed upstream, the SATA SSDs could go back to serial selectors (optional, the WWID is as good, [why](#disk-selectors)). |
| `EthernetConfig` alias | `EthernetConfig` does not resolve link aliases (v1.14.4, the name is passed as is to ethtool), the node files use the kernel interface names (`enp2s0`, `eno1`). If fixed upstream, move it back to `patches/network.yaml.j2` with `name: lan0`. |
| TPM unlock failure | Once, on kube-01, the first boot after the upgrade to the schematic with `drbd` could not unlock `STATE` (`no signatures matching PCR SHA256 digest found in signature JSON`, then `no handlers available to get encryption keys from`). A cold power cycle fixed it. Not reproduced afterwards: several reboots of kube-01 (same PCR 11 value every time), reboots and the same upgrade on kube-03. Fast Boot is off (*Thorough*) on both. Keep a console at hand during the next Talos upgrades; if it happens again, note the boot (first one after an upgrade or not) and the console lines before the error, then report it to Sidero Labs. |
| Dell firmware | *Microsoft UEFI CA* disabled on kube-01 (*Enable for Option ROM* not needed, the iGPU test pod works). Same on kube-03 if its firmware offers the option. |
| Remote power cycle and console | [To study](#remote-node-management). |
