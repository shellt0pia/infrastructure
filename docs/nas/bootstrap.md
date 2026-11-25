# NAS: first deployment

Deploying Doco-CD on the NAS, the stacks of the web UIs, then Zerobyte. Architecture: [README.md](README.md).

*Not tested yet*: the steps follow the documentation of [Doco-CD](https://doco.cd/v0.134/Advanced/Self-Updating/), `community.docker`, Traefik, [dnsweaver](https://maxfield-allison.github.io/dnsweaver/), oauth2-proxy and [Zerobyte](https://zerobyte.app/docs/guides/provisioning). Create every prerequisite of a step before starting it, then follow the steps in order.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 3 | The pool of the Apps exists: the playbook sets it as the pool of the Apps service, which starts Docker. | TrueNAS, *Storage* | To do |
| 3 | SSH to `nas-01.shelltopia.net` as `truenas_admin` with the key of the workstation, and `sudo`. | TrueNAS, *Credentials → Users*, *System → Services → SSH* | To check |
| 3 | A dataset for the files of Doco-CD (the token file). Not `/home/truenas_admin`: its persistence across the upgrades is not known. | TrueNAS, *Datasets* | To do |
| 3 | `community.docker` in `ansible/requirements.yml`, installed: `ansible-galaxy collection install -r requirements.yml` from `ansible/`. | Workstation | To do |
| 4 | Two addresses for Traefik in VLAN 14, outside the DHCP pool, the same host part: `192.168.14.<x>` and `fd38:4c4d:8f66:e::<x>`, written in the [reference](../reference.md#addresses). | OPNsense, *Services → DHCP* | To do |
| 4 | Firewall: the LAN and VPN clients to the addresses of Traefik, TCP 80 and 443; the NAS to `fw-01.shelltopia.net`, TCP 8443 (dnsweaver). | OPNsense, *Firewall → Rules* | To do |
| 4 | A user `dnsweaver` without login, with the privilege of the Unbound API only, and an API key: the key in `username`, the secret in `credential` of `fw-01-dnsweaver` (`nas` vault). | OPNsense, *System → Access → Users* | To do |
| 4 | A token *Zone: DNS: Edit* on `shelltopia.net` only, item `cloudflare-traefik` (`nas` vault, field `credential`). | Cloudflare, *My Profile → API Tokens* | To do |
| 4 | Group `nas_admins`. Client `oauth2-proxy`, confidential, callback `https://oauth2-proxy.nas-01.shelltopia.net/oauth2/callback`, allowed to `nas_admins`: item `pocket-id-oauth2-proxy` (`username`: the client id, `credential`: the secret, `cookie-secret`: `openssl rand -base64 32 \| tr -- '+/' '-_'`). | Pocket ID | To do |
| 4 | A dataset for Traefik (`acme.json`). | TrueNAS, *Datasets* | To do |
| 5 | The workstation service account reads the `nas` vault: `just tofu apply backblaze` reads `restic-nas`. | A new service account, at a [rotation](../secrets/runbook.md#rotating-the-workstation-token) | To do |
| 5 | Item `restic-nas` in the `nas` vault, and the other prerequisites of the NAS backups. | [backups](../backups/bootstrap.md#prerequisites) | To do |
| 5 | Item `nas-01-zerobyte` (`nas` vault): `app-secret` from `openssl rand -hex 32`; `username` and `password` filled at the first start. | 1Password | To do |
| 5 | Client `zerobyte`, confidential, allowed to `nas_admins`, the callback shown by the SSO settings of Zerobyte: item `pocket-id-zerobyte`. | Pocket ID | To do |
| 5 | Datasets for the data of Zerobyte (`/var/lib/zerobyte`) and for the restores (a scratch dataset). | TrueNAS, *Datasets* | To do |

## 1. 1Password

- [ ] **Vault**, with the personal account:

  ```sh
  host-spawn op vault create nas
  ```

- [ ] **Service account**, read-only on the `nas` vault only:

  ```sh
  host-spawn op service-account create "nas-doco-cd" --vault nas:read_items
  ```

  The permissions of a service account cannot be changed after its creation, and the token is shown **only once**.

- [ ] **Item.** Store the token in the `infrastructure` vault, item `1password-doco-cd`, field `credential` (*API Credential* category).
- [ ] **Scope.** The inner `op` uses the workstation service account, the outer one the token of Doco-CD:

  ```sh
  OP_SERVICE_ACCOUNT_TOKEN="$(opsa op read op://infrastructure/1password-doco-cd/credential)" op vault list
  ```

  Expected: **only** the `nas` vault.

## 2. Repository

- [ ] **Compose file of Doco-CD**, `docker/nas-01/doco-cd/compose.yaml`. The image pinned with its digest, the path of the token on the dataset of the [prerequisites](#prerequisites):

  ```yaml
  ---
  services:
    doco-cd:
      image: ghcr.io/kimdre/doco-cd:<version>@sha256:<digest>
      # No container_name and no published port: the self-update starts the new container next
      # to the old one (scale_out). docs/nas/README.md
      restart: unless-stopped
      environment:
        LOG_LEVEL: info
        SELF_UPDATE_ENABLED: "true"
        DEPLOY_CONFIG_BASE_DIR: docker/nas-01/
        POLL_CONFIG: |
          - url: https://github.com/shellt0pia/infrastructure.git
            reference: migrate-to-k8s # the branch of Flux, main after the merge
            interval: 1h
        SECRET_PROVIDER: 1password
        SECRET_PROVIDER_ACCESS_TOKEN_FILE: /run/secrets/op-token
        # Shared daily limit of 1Password: docs/secrets/README.md#rate-limits
        SECRET_PROVIDER_CACHE_ENABLED: "true"
        SECRET_PROVIDER_CACHE_TTL: 12h
      secrets:
        - op-token
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock
        - data:/data
      healthcheck:
        test: ["CMD", "/doco-cd", "healthcheck"]

  secrets:
    op-token:
      file: /mnt/<pool>/<dataset>/op-token # written by ansible/nas.yml

  volumes:
    data: # never renamed: the self-update cannot migrate it
  ```

- [ ] **Configuration of the deployments**, `docker/nas-01/.doco-cd.yml`:

  ```yaml
  ---
  working_dir: docker/nas-01/ # relative to the root of the repository
  auto_discovery:
    enabled: true
    depth: 1
    delete: true
  ```

- [ ] **Playbook.** `ansible/inventories/nas.yml` (`nas-01.shelltopia.net`, `ansible_user: truenas_admin`, the pool of the Apps, the path of the token), `ansible/nas.yml` and its roles:
  - `ansible/roles/truenas_docker`: the pool of the Apps service when none is set (`midclt call docker.config`, then `midclt call -j docker.update`, [open point](evaluations.md#open-points)), the bridge network `proxy` with IPv6 (`community.docker.docker_network`);
  - `ansible/roles/doco_cd`: read the token (`op read` on `localhost`, `no_log`), write the file (`0600`, `become`), start the project `doco-cd` from the Compose file of the repository (`community.docker.docker_compose_v2`), wait for the container to be healthy.
- [ ] **Checks**, at the root of the repository:

  ```sh
  yamllint -c .yamllint.yml docker/nas-01 ansible/nas.yml ansible/inventories/nas.yml ansible/roles/truenas_docker ansible/roles/doco_cd
  (cd ansible && ansible-lint nas.yml)
  ```

  Expected: no error.

- [ ] **Push.** Doco-CD reads the branch from GitHub, not the files of the workstation.

## 3. Bootstrap of Doco-CD

From `ansible/`.

- [ ] **Dry run:**

  ```sh
  opsa ansible-playbook --inventory=inventories/nas.yml nas.yml --check --diff
  ```

  Expected: the connection and `become` work, the pool of the Apps, the network `proxy`, the token file and the project `doco-cd` show as changes, and no token is printed.

- [ ] **Bootstrap:**

  ```sh
  opsa ansible-playbook --inventory=inventories/nas.yml nas.yml --diff
  ```

  Then on the NAS (`ssh truenas_admin@nas-01.shelltopia.net`):

  ```sh
  sudo midclt call docker.config
  sudo docker version
  sudo docker network ls --filter name=proxy
  sudo docker compose ls
  sudo docker ps --filter label=com.docker.compose.project=doco-cd
  sudo docker logs --tail 50 <container>
  ```

  Expected: the pool of the Apps set, the versions of Docker and Compose noted ([open point](evaluations.md#open-points)), the network `proxy`, the project `doco-cd` running, its container `healthy`, the first poll of the repository in the logs, without 1Password errors. A second run of the playbook changes nothing.

- [ ] **Takeover.** After the first poll:

  ```sh
  sudo docker ps --filter label=com.docker.compose.project=doco-cd --format '{{.Names}} {{.Status}} {{.CreatedAt}}'
  ```

  Expected, to confirm: a single container, created after the bootstrap, `healthy`. The logs of the old one show the handover to its successor.

- [ ] **Self-update.** Change `LOG_LEVEL` to `debug` in `docker/nas-01/doco-cd/compose.yaml`, push, and wait for the next poll (up to an hour). Same command as above.

  Expected: a new container, `healthy`, replaced the previous one; still a single container. Revert the commit afterwards.

- [ ] **Requests to 1Password.** The day after, with the personal account:

  ```sh
  host-spawn op service-account ratelimit nas-doco-cd
  ```

  Expected: a few requests per hour at most. Otherwise, see the [open point](evaluations.md#open-points). Again after step 5, with every stack.

## 4. Web UIs: Traefik, dnsweaver, oauth2-proxy

- [ ] **Traefik**, `docker/nas-01/traefik/compose.yaml`. Staging certificates first. The addresses of the [prerequisites](#prerequisites), the gateways the addresses of OPNsense on VLAN 14:

  ```yaml
  ---
  services:
    traefik:
      image: docker.io/library/traefik:<version>@sha256:<digest>
      restart: unless-stopped
      command:
        - --global.checkNewVersion=false
        - --global.sendAnonymousUsage=false
        - --ping=true
        - --api.dashboard=true
        - --entrypoints.web.address=:80
        - --entrypoints.web.http.redirections.entrypoint.to=websecure
        - --entrypoints.web.http.redirections.entrypoint.scheme=https
        - --entrypoints.websecure.address=:443
        - --entrypoints.websecure.http.tls.certresolver=le
        - --entrypoints.websecure.http.tls.domains[0].main=*.nas-01.shelltopia.net
        - --providers.docker.endpoint=tcp://cetusguard:2375
        - --providers.docker.exposedbydefault=false
        - --providers.docker.network=proxy
        - --certificatesresolvers.le.acme.email=<email>
        - --certificatesresolvers.le.acme.storage=/data/acme.json
        # Removed once the staging certificate is served
        - --certificatesresolvers.le.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory
        - --certificatesresolvers.le.acme.dnschallenge.provider=cloudflare
        - --certificatesresolvers.le.acme.dnschallenge.resolvers=1.1.1.1:53,1.0.0.1:53
      environment:
        CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}
      volumes:
        - /mnt/<pool>/<dataset>:/data
      networks:
        lan:
          # Docker takes no name: the addresses of docs/reference.md#addresses
          ipv4_address: 192.168.14.<x>
          ipv6_address: fd38:4c4d:8f66:e::<x>
          # The answers to the other VLANs leave through vlan14, not the NAT of the bridge
          gw_priority: 1
        proxy: {}
        cetusguard: {}
      healthcheck:
        test: ["CMD", "traefik", "healthcheck", "--ping"]
      labels:
        traefik.enable: "true"
        traefik.http.routers.dashboard.rule: Host(`traefik.nas-01.shelltopia.net`)
        traefik.http.routers.dashboard.service: api@internal
        traefik.http.routers.dashboard.middlewares: oauth2-proxy@docker

    cetusguard:
      image: docker.io/hectorm/cetusguard:<version>@sha256:<digest>
      restart: unless-stopped
      read_only: true
      environment:
        CETUSGUARD_BACKEND_ADDR: unix:///var/run/docker.sock
        CETUSGUARD_FRONTEND_ADDR: tcp://:2375
        CETUSGUARD_RULES: |
          ! Monitor events
          GET %API_PREFIX_EVENTS%
          ! List containers
          GET %API_PREFIX_CONTAINERS%/json
          ! Inspect a container
          GET %API_PREFIX_CONTAINERS%/%CONTAINER_ID_OR_NAME%/json
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock:ro
      networks:
        - cetusguard

  networks:
    lan:
      driver: macvlan
      driver_opts:
        parent: vlan14
      enable_ipv6: true
      ipam:
        config:
          - subnet: 192.168.14.0/24
            gateway: 192.168.14.<gateway>
            ip_range: 192.168.14.<x>/32 # Docker never hands out another address
          - subnet: fd38:4c4d:8f66:e::/64
            gateway: fd38:4c4d:8f66:e::<gateway>
            ip_range: fd38:4c4d:8f66:e::<x>/128
    proxy:
      external: true # created by ansible/nas.yml
    cetusguard:
      internal: true
  ```

  Secrets, `docker/nas-01/traefik/.doco-cd.yml`: `CF_DNS_API_TOKEN: op://nas/cloudflare-traefik/credential`.

- [ ] **oauth2-proxy**, `docker/nas-01/oauth2-proxy/compose.yaml`, on the network `proxy` only:
  - `OAUTH2_PROXY_PROVIDER=oidc`, `OAUTH2_PROXY_OIDC_ISSUER_URL=https://id.shelltopia.org`, the client id, secret and cookie secret from `pocket-id-oauth2-proxy` (`.doco-cd.yml`);
  - `OAUTH2_PROXY_REDIRECT_URL=https://oauth2-proxy.nas-01.shelltopia.net/oauth2/callback`, `OAUTH2_PROXY_COOKIE_DOMAINS` and `OAUTH2_PROXY_WHITELIST_DOMAINS` `.nas-01.shelltopia.net`, `OAUTH2_PROXY_ALLOWED_GROUPS=nas_admins`, the scope `openid email profile groups`, `OAUTH2_PROXY_EMAIL_DOMAINS=*`;
  - `OAUTH2_PROXY_REVERSE_PROXY=true`, `OAUTH2_PROXY_SET_XAUTHREQUEST=true`, `OAUTH2_PROXY_UPSTREAMS=static://202`: a request without session is redirected to Pocket ID, the others get a `202`;
  - labels: its router on `oauth2-proxy.nas-01.shelltopia.net` (port 4180), and the middleware `oauth2-proxy`: `forwardAuth` to `http://oauth2-proxy:4180/`, `trustForwardHeader`, `authResponseHeaders` `X-Auth-Request-User,X-Auth-Request-Email`.
- [ ] **dnsweaver**, `docker/nas-01/dnsweaver/compose.yaml`: dnsweaver and its cetusguard (the same rules as the one of Traefik) on an `internal` network, dnsweaver also on the default network of the project to reach OPNsense, its Docker endpoint `tcp://cetusguard:2375`. Its two instances:

  ```yaml
  environment:
    DNSWEAVER_SOURCES: traefik
    DNSWEAVER_INSTANCES: unbound-a,unbound-aaaa
    DNSWEAVER_UNBOUND_A_TYPE: opnsense
    DNSWEAVER_UNBOUND_A_URL: https://fw-01.shelltopia.net:8443
    DNSWEAVER_UNBOUND_A_API_KEY: ${OPNSENSE_API_KEY}
    DNSWEAVER_UNBOUND_A_API_SECRET: ${OPNSENSE_API_SECRET}
    DNSWEAVER_UNBOUND_A_ENGINE: unbound
    DNSWEAVER_UNBOUND_A_RECORD_TYPE: A
    DNSWEAVER_UNBOUND_A_TARGET: 192.168.14.<x> # Traefik, docs/reference.md#addresses
    DNSWEAVER_UNBOUND_A_DOMAINS: "*.nas-01.shelltopia.net"
    # The same for DNSWEAVER_UNBOUND_AAAA_*: RECORD_TYPE AAAA, TARGET fd38:4c4d:8f66:e::<x>
  ```

  Secrets, `.doco-cd.yml`: `OPNSENSE_API_KEY: op://nas/fw-01-dnsweaver/username`, `OPNSENSE_API_SECRET: op://nas/fw-01-dnsweaver/credential`.

- [ ] **Checks**, after the push and the next poll. On the NAS:

  ```sh
  sudo docker compose ls
  sudo docker exec <traefik> ip route
  sudo docker exec <traefik> ip -6 addr
  sudo docker exec <traefik> ip -6 route
  sudo docker logs --tail 50 <dnsweaver>
  ```

  Expected: the projects `traefik`, `oauth2-proxy` and `dnsweaver` running; the default routes of Traefik through `vlan14`; only its static ULA, no SLAAC address ([open point](evaluations.md#open-points)); dnsweaver created the records of `traefik` and `oauth2-proxy`.

  From a client of another VLAN:

  ```sh
  dig +short traefik.nas-01.shelltopia.net A
  dig +short traefik.nas-01.shelltopia.net AAAA
  dig +short nas-01.shelltopia.net A
  curl -skI https://traefik.nas-01.shelltopia.net
  ```

  Expected: the addresses of Traefik; `nas-01.shelltopia.net` still the address of the NAS; a redirect to `id.shelltopia.org`. In OPNsense, *Services → Unbound DNS → Overrides*: the host overrides with `dnsweaver:unbound-a` and `dnsweaver:unbound-aaaa` as description.

- [ ] **Production certificate.** Remove the `caserver` line, delete `acme.json` on the dataset, push. Expected: the browser accepts `https://traefik.nas-01.shelltopia.net`, the login of a user of `nas_admins` opens the dashboard, a user outside of the group is refused.

## 5. Zerobyte

- [ ] **Compose file**, `docker/nas-01/zerobyte/compose.yaml`. First without provisioning: the provisioning needs the id of an existing organization.

  ```yaml
  ---
  services:
    zerobyte:
      image: ghcr.io/nicotsx/zerobyte:<version>@sha256:<digest>
      restart: unless-stopped
      environment:
        TZ: Europe/Paris
        BASE_URL: https://zerobyte.nas-01.shelltopia.net
        TRUST_PROXY: "true"
        APP_SECRET: ${ZEROBYTE_APP_SECRET}
        RESTIC_HOSTNAME: nas-01
        WEBHOOK_ALLOWED_ORIGINS: https://hc-ping.com
        # Read by the provisioning (env://), never written in its file
        NAS_RESTIC_PASSWORD: ${NAS_RESTIC_PASSWORD}
        NAS_B2_ACCESS_KEY_ID: ${NAS_B2_ACCESS_KEY_ID}
        NAS_B2_SECRET_ACCESS_KEY: ${NAS_B2_SECRET_ACCESS_KEY}
      volumes:
        - /mnt/<pool>/<dataset>:/var/lib/zerobyte
        - /mnt/<pool>/<documents>:/data/documents:ro
        - /mnt/<pool>/<groupware>:/data/groupware:ro
        - /mnt/<pool>/<media>/library:/data/media:ro
        - /mnt/<pool>/<scratch>:/restore
      networks:
        - proxy
      labels:
        traefik.enable: "true"
        traefik.http.routers.zerobyte.rule: Host(`zerobyte.nas-01.shelltopia.net`)
        traefik.http.services.zerobyte.loadbalancer.server.port: "4096"

  networks:
    proxy:
      external: true # created by ansible/nas.yml
  ```

  No `SYS_ADMIN` nor `/dev/fuse`, no published port. The datasets to back up are those of the [backups](../backups/bootstrap.md#3-nas-data-zerobyte).

- [ ] **Secrets**, `docker/nas-01/zerobyte/.doco-cd.yml`:

  ```yaml
  ---
  external_secrets:
    ZEROBYTE_APP_SECRET: op://nas/nas-01-zerobyte/app-secret
    NAS_RESTIC_PASSWORD: op://nas/restic-nas/password
    NAS_B2_ACCESS_KEY_ID: op://nas/restic-nas/access-key-id
    NAS_B2_SECRET_ACCESS_KEY: op://nas/restic-nas/secret-access-key
  ```

- [ ] **First start.** Push, then after the next poll open `https://zerobyte.nas-01.shelltopia.net`: create the owner account (in `nas-01-zerobyte`, `username` and `password`), then copy the organization id (*Settings → Organization*).
- [ ] **Provisioning.** Add `PROVISIONING_PATH: /config/provisioning.json` and the file inline, with the bucket of `restic-nas`:

  ```yaml
  services:
    zerobyte:
      configs:
        - source: provisioning
          target: /config/provisioning.json

  configs:
    provisioning:
      content: |
        {
          "version": 1,
          "repositories": [
            {
              "id": "nas",
              "organizationId": "<organization id>",
              "name": "nas",
              "backend": "s3",
              "compressionMode": "auto",
              "config": {
                "backend": "s3",
                "endpoint": "https://s3.<region>.backblazeb2.com",
                "bucket": "<bucket>",
                "accessKeyId": "env://NAS_B2_ACCESS_KEY_ID",
                "secretAccessKey": "env://NAS_B2_SECRET_ACCESS_KEY",
                "customPassword": "env://NAS_RESTIC_PASSWORD",
                "isExistingRepository": false
              }
            }
          ],
          "volumes": [
            {"id": "documents", "organizationId": "<organization id>", "name": "documents", "backend": "directory", "config": {"backend": "directory", "path": "/data/documents"}},
            {"id": "groupware", "organizationId": "<organization id>", "name": "groupware", "backend": "directory", "config": {"backend": "directory", "path": "/data/groupware"}},
            {"id": "media", "organizationId": "<organization id>", "name": "media", "backend": "directory", "config": {"backend": "directory", "path": "/data/media"}}
          ]
        }
  ```

  Push. Expected after the next poll: the repository and the three volumes in Zerobyte, marked as managed; the repository initialized in the bucket. Then `isExistingRepository: true`, so that a new instance never runs `restic init` again.

- [ ] **SSO.** In the SSO settings of Zerobyte, Pocket ID as OIDC provider (issuer `https://id.shelltopia.org`, the client of `pocket-id-zerobyte`). Expected: the login through Pocket ID works, the local account still works.
- [ ] **Jobs, first backups and restore test:** [backups](../backups/bootstrap.md#3-nas-data-zerobyte).
