# Documentation

- [first-bootstrap.md](first-bootstrap.md): the order of the first bootstrap, linking to the `bootstrap.md` of each topic.
- [roadmap.md](roadmap.md): what is left to build and the open questions.
- [tofu/README.md](../tofu/README.md): the OpenTofu stacks (Cloudflare, Backblaze).

## Topics

### Format

Each topic has its own folder, with the same files (only those with content):

| File | Content |
| --- | --- |
| `README.md` | The architecture: what it is, why, the status and the decisions. |
| `bootstrap.md` | The first deployment: prerequisites, then the steps in order, with checkboxes. |
| `runbook.md` | The day-to-day recipes and procedures. |
| `evaluations.md` | What was tested or considered and set aside, and the open points. |

### List

| Topic | Content |
| --- | --- |
| [Nodes](nodes/README.md) | The machines: hardware, BIOS, Secure Boot, TPM disk encryption, Talos image. |
| [Network](network/README.md) | OPNsense: DHCP, router advertisements, names, firewall, BGP, IPv6 prefix change. |
| [Cluster](cluster/README.md) | Bootstrap, Cilium, CoreDNS, Flux, GPU. |
| [Secrets](secrets/README.md) | 1Password: the workstation service account, External Secrets. |
| [Storage](storage/README.md) | Piraeus/LINSTOR and NFS. |
| [Ingress](ingress/README.md) | Envoy Gateway, the Gateways, the certificate, HAProxy on OPNsense. |
| [DNS](dns/README.md) | k8s-gateway, external-dns, cloudflare-ddns, OpenTofu records. |
| [Backups](backups/README.md) | VolSync and restic on Backblaze B2, Backrest for the NAS. |
