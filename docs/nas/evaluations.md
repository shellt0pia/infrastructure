# NAS: evaluations and open points

What was considered to deploy containers on the NAS, to bootstrap Doco-CD and to reach their web UIs, and what is still pending. The architecture is in [README.md](README.md). Why a restic tool on the NAS rather than the backup tasks of TrueNAS, and why Zerobyte rather than Backrest: [backups](../backups/evaluations.md#rejected-options).

## Deploying containers on the NAS

Kept: **Doco-CD** ([README](README.md#containers-from-git-doco-cd)).

- For: light (one Go binary, no database), declarative (plain Compose files and a `.doco-cd.yml`), polling, the prune of the removed stacks, 1Password, the self-update. The Compose files stay plain: another tool could read the same folders.
- Against: a young project (0.x, frequent releases), mainly one maintainer, no real UI (its logs, a REST API and metrics).

| Option | Why not |
| --- | --- |
| TrueNAS Apps, or *Custom App* YAML | The configuration lives in the middleware, not in Git, and nothing reconciles it. |
| Push to the API of the Apps (`app.create`, `app.update` through `midclt` or JSON-RPC) | No reconciliation, and an API key of the NAS on the workstation. The OpenTofu providers of TrueNAS were not checked. |
| Komodo | Heavier: Core, Periphery, and MongoDB or FerretDB. Part of the state lives in Komodo. |
| Portainer CE | Heavy, its configuration not in Git, the useful features in the Business edition. |
| Dockge | No synchronisation from Git. |
| Cron of `git pull` and `docker compose up` | A script on the host, no prune, the secrets in `.env` files. |
| Zerobyte in the cluster | Already rejected for the backups: the data through the single NIC of the nodes, no backups while the cluster is down ([backups](../backups/evaluations.md#rejected-options)). |
| A Talos VM on the NAS | Overkill for a few containers. |

## Bootstrapping Doco-CD

Kept: **Ansible, then the self-update** ([README](README.md#bootstrap-ansible-then-doco-cd-updates-itself)).

| Option | Why not |
| --- | --- |
| A *Custom App* of TrueNAS for the first container | The project `ix-doco-cd` would be owned by both the middleware and Doco-CD. |
| A `just` recipe over SSH running `docker run … apply-self --bootstrap` (the bootstrap script of Doco-CD) | Works too. Ansible is preferred: idempotent, the token never in a command line, the same playbook to repair. Kept in mind if the takeover fails ([open points](#open-points)). |
| Ansible only, without the self-update (bjw-s) | Every update of Doco-CD through the playbook. His Compose file says it is not managed by Doco-CD "because it can't manage itself", likely written before the self-update. The fallback. |
| Doco-CD in the cluster, through a Docker context over SSH | Access to the Docker of the NAS is root on the NAS, from the cluster; `restic-nas` would cross the cluster; no deployment while the cluster is down. |
| An *Init/Shutdown Script* of TrueNAS | Depends on the start order of Docker, and a script on the host. |
| Two instances deploying each other | The previous pattern of Doco-CD, replaced by the self-update. |

## Web UIs of the NAS

Kept: **Traefik on its own macvlan address, names in `nas-01.shelltopia.net` created by dnsweaver, Pocket ID** ([README](README.md#independent-of-the-cluster)). Wanted: a name, a Let's Encrypt certificate and port 443, without depending on the cluster.

### Reverse proxy and address

| Option | Why not |
| --- | --- |
| The Envoy of the cluster: an `HTTPRoute` on the `internal` Gateway to a `Backend` of Envoy Gateway, `nas-01-dmz.shelltopia.net` | The name, the certificate and the address already exist, but no web UI while the cluster is down, when a restore matters most. Also needs `extensionApis.enableBackend` and an egress policy for the Envoy proxies. |
| An IP alias on `vlan14`, the web UI of TrueNAS limited to the main address (*System → General Settings → GUI*) | Works too. Changes the configuration of TrueNAS, where macvlan leaves it alone. |
| A `/32` announced in BGP by FRR, as bjw-s does | Overkill for one host: a BGP session from the NAS for one address. |
| The web UI of TrueNAS moved to 8443, Traefik on 443 of the address of the NAS | Moves the web UI of TrueNAS, and the firewall cannot tell Traefik from TrueNAS. |
| Ports published on the address of the NAS, without proxy | No TLS, no names. |
| Caddy | Works as well. Traefik is already known (the Fedora CoreOS hosts), and dnsweaver reads its labels. |

### Names

| Option | Why not |
| --- | --- |
| `<app>.shelltopia.org`, served by k8s-gateway (a route, or a `DNSEndpoint`) | `shelltopia.org` no longer resolves on the LAN while the cluster is down ([dns](../dns/README.md#internal-k8s-gateway)). |
| An authoritative zone outside of the cluster on OPNsense, updated in RFC 2136, for every host and cluster | The BIND plugin of OPNsense is too limited for now, and no other plugin of the community edition takes RFC 2136 updates. PowerDNS Authoritative is in the Business edition only, about 150 $ a year. To revisit. |
| One wildcard host override `*.nas-01.shelltopia.net` | OPNsense writes a wildcard as a `redirect` local zone of its domain (to confirm if reconsidered): `nas-01.shelltopia.net` itself would resolve to Traefik. |
| Host overrides by hand | One more step for each stack, forgotten when it is removed. |
| external-dns with the OPNsense webhook | Runs in the cluster. |
| dexd, as bjw-s does | UniFi only. |

### Login

| Option | Why not |
| --- | --- |
| An OIDC plugin of Traefik | Downloaded from `plugins.traefik.io` at each start unless vendored, run by the Yaegi interpreter. oauth2-proxy is a plain container, mature. |
| oauth2-proxy in front of Zerobyte | Two logins in a row: Zerobyte has its own SSO. |
| No login on the dashboard of Traefik | It shows every route and backend of the NAS. |

## Open points

| Topic | Notes |
| --- | --- |
| Takeover by the self-update | The container started by Ansible must be recognised as the stack `doco-cd` (same project and service name). The documentation asks for the `data` volume as `external: true` in that case; here it is the same project, so the same volume. If the takeover fails, the bootstrap script of Doco-CD (`apply-self --bootstrap`, run by Ansible) creates the container with the labels of a managed stack. To check at the [bootstrap](bootstrap.md#3-bootstrap-of-doco-cd), with the auto-discovery deploying the own stack of Doco-CD. |
| Rate limit of 1Password | 1,000 requests a day for the account, shared with External Secrets and the workstation, about 3 per field ([rate limits](../secrets/README.md#rate-limits)). The stacks have 10 fields: about 720 requests a day if Doco-CD resolves them at every poll, about 60 with the cache of 12 hours ([secrets](README.md#secrets)). Measure at the bootstrap: whether the cache works as expected (in memory: lost at each restart), and whether Doco-CD resolves the secrets of a stack that did not change. Then tune the poll interval and the cache. 1Password Connect is supported by Doco-CD. |
| Persistence across the upgrades of TrueNAS | The Docker volumes of the Apps, the token file on its dataset, SSH and `sudo` of `truenas_admin`: check after the first upgrade ([runbook](runbook.md#after-a-truenas-upgrade)). |
| Running the playbook | `opsa ansible-playbook` by hand for now. A target of `ansible/Makefile` always passes `vault-pass.sh` (the encrypted inventory of the Fedora CoreOS hosts); a `just` recipe is the alternative. |
| `community.docker` on TrueNAS | `docker_compose_v2` needs the Docker CLI with the Compose plugin, and PyYAML for a definition read on the workstation. To check with the dry run. |
| Pool of the Apps by Ansible | `midclt call -j docker.update '{"pool": "<pool>"}'`, only when `midclt call docker.config` shows no pool. To check with the dry run: the name of the method in 25.10, and that the job waits for Docker to start. |
| Docker and Compose versions of TrueNAS 25.10 | `gw_priority` needs Docker Engine 28 and Compose 2.33, `configs` with `content` Compose 2.23. Without `gw_priority`, the default route of Traefik could be the one of the bridge: its answers to the other VLANs would leave through the NAT of the NAS. Check `docker version` and `ip route` in the container of Traefik. |
| Router advertisements on the macvlan | The container of Traefik may take a SLAAC address and a default route from the router advertisements of VLAN 14, next to its static ULA. Check `ip -6 addr` and `ip -6 route` in the container; otherwise `net.ipv6.conf.all.accept_ra=0` in its `sysctls`. |
| Files of the repository in a container | Doco-CD runs Compose from its clone, inside its own container: a relative bind mount would point to a path of that container, not of the host. Hence Traefik without a configuration file, and the provisioning file of Zerobyte inline (`configs` with `content`). To check with the first stack. |
| Reloads of Unbound by dnsweaver | A recreated container (an update) may remove then create its records: two reloads of Unbound, two short DNS outages on the LAN. Check its logs at the first update of Zerobyte. Otherwise `RECONFIGURE_MODE=never` and a reload planned on OPNsense. |
| Monitoring of Doco-CD | Its metrics need a published port, which forces the `applier` strategy, or a reverse proxy on the network of the project. With the metrics of the NAS ([observability](../observability/README.md#external-devices)). |
| Next stacks | The exporters (`node_exporter`, `smartctl_exporter`), scraped from the cluster: on the address of the NAS, not behind Traefik ([observability](../observability/README.md#external-devices)). |
