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

### Make

The `Makefile` contains all the useful commands to manage the infrastructure, run `make help` to see the list of available commands.

### Secrets management

All the secrets are stored in the `inventories/production.yml` which is encrypted using `ansible-vault`. The `vault-pass.sh` uses the bitwarden CLI to retrieve the vault password from my 1Password vault.

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
- `tasks/remove.yml`: Remove all the services resources (created by `create.yml`)
- `templates/*.container.j2`: Podman container quadlet templates

Run `make provision` to provision all the hosts using Ansible.

### Updating

All the hosts are configured to auto-update:

- Their OS every week using `zincati`.
- Their containers using "custom" systemd timers that pull the latest image before `zincati` execution and eventual host reboot. If the host didn't reboot an other script recreate the containers that have pulled a new image.

Run `make update` to update services when a tag has changed.

Run `make db-upgrade` when updating to a new PostgreSQL major version.

## License

This project is released under the [BSD 3-Clause License](https://opensource.org/licenses/BSD-3-Clause). A copy of the license is available in this project folder.
