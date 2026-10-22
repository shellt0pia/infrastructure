# Infrastructure

This is a mono repository for my home infrastructure, managed with Ansible.

## Stack Overview

I have a DELL Optiplex Micro to run my home workloads and a Hetzner VM to run my "critical" services that need to be always online even when my home network is down.

As well as the following resources :

- An OPNsense firewall with:
  - A public IPv4 and IPv6 prefix.
  - Unbound configured with A+AAAA records for each hosts.
  - HAProxy as a transparent SNI proxy to route external IPv4 HTTPS traffic to the proper host based on the SNI header.
- A DNS zone for my public domain name managed by Cloudflare.
- A TrueNAS server that host all my files and provide NFS exports to my containers hosts.

I chose the following software stack for my container hosts:

- OS : Fedora CoreOS, I already use Fedora Silverblue on my desktop and laptop and I also wanted an atomic fedora OS for my servers.
- Services runtime : Podman with systemd quadlets units to manage the containers.

## Codebase Overview

### Tooling

The CLI tools (Ansible, talosctl, kubectl, helmfile, OpenTofu...) are pinned in `mise.toml`, run `mise install` to install them. kubectl and talosctl follow the versions deployed on the cluster (`talos/vars.yaml`). `mise` also points `KUBECONFIG` and `TALOSCONFIG` to the files generated at the repository root, and `MINIJINJA_CONFIG_FILE` to the `minijinja-cli` flags (`.minijinja.toml`).

`just` and `jq` are expected to be installed on the system. The 1Password CLI (`op`) runs in the toolbox with a read-only service account, the personal account through `host-spawn op`, see [docs/1password-local-access.md](docs/1password-local-access.md).

### Make

The `Makefile` contains all the useful commands to manage the infrastructure, run `make help` to see the list of available commands.

### Secrets management

All the secrets are stored in the `inventories/production.yml` which is encrypted using `ansible-vault`. The `vault-pass.sh` script reads the vault password from the `personal` 1Password vault with the 1Password CLI (`host-spawn op`, through the desktop app).

Run `make vault` to edit the `production.yml` inventory in your `$EDITOR`.

### OS provisioning

Fedora CoreOS uses Ignition to provision the OS on first boot. The Ignition files are generated using Butane files stored in the `templates/coreos/` folder as jinja templates.

The `ignition.yml` playbook will template the butane files and generate the Ignition files in the `files/coreos/` folder and serve them using a simple Python HTTP Server on port 8000.

### Ansible provisioning

The Ansible code configures and deploys the following:

- The Fedora CoreOS hosts (networking, NFS mounts, Podman installation etc.)
- All the containerized services running on the Fedora CoreOS hosts

The `example.yml` inventory contains an example of how to structure the inventory file and contains all the possible variables as well as comments to explain how to generated certain values.

The services roles follow the following structure:

- `tasks/create.yml`: Create all the necessary resources (DNS records, bind mounts, networks, containers etc.)
- `tasks/lifecycle.yml`: Start/Stop/Restart/Enable/Disable the services containers
- `tasks/db-upgrade.yml`: Upgrade the database schema if doing a major version upgrade
- `tasks/restore.yml`: Restore the host containers data from its backup repository (`resticprofile` role only)
- `tasks/remove.yml`: Remove all the services resources (created by `create.yml`)
- `templates/*.container.j2`: Podman container quadlet templates

Run `make provision` to provision all the hosts using Ansible.

### Updating

All the hosts are configured to auto-update:

- Their OS every week using `zincati`.
- Their containers using "custom" systemd timers that pull the latest image before `zincati` execution and eventual host reboot. If the host didn't reboot an other script recreate the containers that have pulled a new image.

Run `make update` to update services when a tag has changed.

Run `make db-upgrade` when updating to a new PostgreSQL major version.

### Restoring

The hosts running the `resticprofile` role back up their containers data (`data` folder of the containers storage, through its daily Btrfs snapshot) to their own restic repository.

To rebuild a host from scratch, provision it with `make provision limit=<host>` then run `make restore limit=<host>` to stop all its services, restore its containers data from the latest snapshot (or a specific one with `snapshot=<restic snapshot ID>`) and start its services again. The previous containers data is kept in a `data.pre-restore-<timestamp>` folder next to the restored one, delete it once the restore is validated.

Run `sudo resticprofile snapshots` on the host to list the available snapshots.

## Kubernetes (WIP)

The services of the Hetzner VM are being migrated to a 3-node Talos Linux cluster. All the commands are [just](https://just.systems) recipes, run `just` to list them.

| Path | Content |
| --- | --- |
| `talos/` | Talos machine configs: `talosctl gen config` + minijinja patches rendered with `talos/vars.yaml`, Image Factory schematic. |
| `bootstrap/` | One-shot cluster bootstrap: secrets from 1Password and helmfile installing External Secrets and Flux. |
| `kubernetes/apps/` | Flux root path, one directory per namespace, one Flux `Kustomization` (`ks.yaml`) per app. |
| `tofu/` | OpenTofu stacks (Cloudflare), the state is encrypted and committed. |

Secrets are stored in 1Password:

- `infrastructure` vault: Talos secrets bundle, bootstrap and OpenTofu secrets, read locally through the workstation service account.
- `kubernetes` vault: application secrets, read by External Secrets through a service account.

Bootstrap from nodes booted on the Talos ISO (`just talos download-image`), in maintenance mode, once the prerequisites of [docs/first-bootstrap.md](docs/first-bootstrap.md) are done:

```sh
just talos gen-secrets   # one-time
just bootstrap cluster   # talosconfig, machine configs, etcd, kubeconfig, secrets, CRDs, External Secrets and Flux
```

The charts installed by `bootstrap/helmfile` read their source, version and values from `kubernetes/apps`, Flux adopts the releases afterwards. Versions are updated by Renovate (`.renovaterc.json5`).

## License

This project is released under the [BSD 3-Clause License](https://opensource.org/licenses/BSD-3-Clause). A copy of the license is available in this project folder.
