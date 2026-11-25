# NAS: runbook

Day-to-day administration of the containers of the NAS. Architecture: [README.md](README.md).

*Not tested yet*: written before the first deployment.

The commands on the NAS run over SSH (`ssh truenas_admin@nas-01.shelltopia.net`), with `sudo`. Doco-CD has no UI: its logs say what it deployed. The other web UIs are at `https://<app>.nas-01.shelltopia.net`, behind Traefik ([README](README.md#reverse-proxy-traefik-on-its-own-address)).

```sh
sudo docker ps --filter label=com.docker.compose.project=doco-cd
sudo docker logs --tail 100 <container>
```

## Adding a stack

- [ ] **Folder** `docker/nas-01/<stack>/`, with a `compose.yaml`:
  - images pinned as `<version>@sha256:<digest>`, for Renovate;
  - a restart policy, and a healthcheck when the image has one;
  - the data on a dataset (bind mount) or in a named volume;
  - the secrets in a `.doco-cd.yml` next to it (`external_secrets`, from the `nas` vault, [secrets](README.md#secrets)). Each field costs requests to 1Password ([rate limits](../secrets/README.md#rate-limits)).
  - a web UI: the external network `proxy`, no published port, the labels `traefik.enable`, a router on `Host(\`<app>.nas-01.shelltopia.net\`)` and the port of its service. Its login: its own OIDC with Pocket ID when it has one, the middleware `oauth2-proxy@docker` otherwise, never both ([login](README.md#login)). dnsweaver creates its name.
- [ ] **Checks:**

  ```sh
  yamllint -c .yamllint.yml docker/nas-01/<stack>
  ```

- [ ] **Push**, then on the NAS after the next poll (up to an hour):

  ```sh
  sudo docker compose ls
  sudo docker compose -p <stack> ps
  ```

  Expected: the project running, its containers `healthy` when they have a healthcheck. With a web UI: `https://<app>.nas-01.shelltopia.net` answers, after the login.

## A name that does not resolve

- [ ] **dnsweaver** saw the container and wrote the record:

  ```sh
  sudo docker logs --tail 100 <dnsweaver>
  ```

  A `Host()` rule outside of `*.nas-01.shelltopia.net` is ignored; an `unauthorized` is the API key of `fw-01-dnsweaver`.

- [ ] **OPNsense**, *Services → Unbound DNS → Overrides*: the host override, with `dnsweaver:unbound-a` or `dnsweaver:unbound-aaaa` as description. A description changed by hand detaches it from dnsweaver.
- [ ] **The client** asks Unbound: `dig <app>.nas-01.shelltopia.net @<address of OPNsense>`.

## The certificate

Traefik renews the wildcard `*.nas-01.shelltopia.net` on its own, 30 days before its end. A renewal that fails shows in its logs (`acme`, `cloudflare`): the token `cloudflare-traefik` expired or was removed, or Cloudflare is out of reach. The current certificate stays served until its end.

```sh
sudo docker logs <traefik> 2>&1 | grep -i acme
echo | openssl s_client -connect traefik.nas-01.shelltopia.net:443 -servername traefik.nas-01.shelltopia.net 2>/dev/null | openssl x509 -noout -issuer -dates
```

After a new token: the item, then a restart of Traefik once Doco-CD resolved it (the cache of 12 hours: restart Doco-CD first).

## Reaching Zerobyte without Traefik or Pocket ID

Traefik down, the names gone, or Pocket ID out of reach (internet down): Zerobyte keeps running, and its backups too.

- Pocket ID out of reach: the local account of `nas-01-zerobyte`, on the usual address.
- Traefik or the names down: a tunnel to its address on the network `proxy`, from the workstation:

  ```sh
  ssh truenas_admin@nas-01.shelltopia.net sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' <zerobyte>
  ssh -L 4096:<address>:4096 truenas_admin@nas-01.shelltopia.net
  ```

  Then `http://localhost:4096`, with the local account. `BASE_URL` is `https`: the session cookie is `Secure`, which browsers accept on `localhost`.

## Removing a stack

Never `docker/nas-01/doco-cd`: Doco-CD would remove itself.

- [ ] **Removal from Git.** Remove `docker/nas-01/<stack>/`, push, then after the next poll:

  ```sh
  sudo docker compose ls
  sudo docker volume ls --filter label=com.docker.compose.project=<stack>
  ```

  Expected: the project is gone, its named volumes are still there (`remove_volumes: false`).

- [ ] **Cleanup**, once the data is no longer needed: `sudo docker volume rm <volume>`, and the datasets of the stack in TrueNAS.

## Updating Doco-CD

Renovate opens the pull request of the image. Read the release notes first: the project is young and changes often. Merge, then after the next poll:

```sh
sudo docker ps --filter label=com.docker.compose.project=doco-cd --format '{{.Image}} {{.Status}} {{.CreatedAt}}'
```

Expected: a single container, with the new image, `healthy`.

- **The update failed:** Doco-CD rolls back to the previous container, which keeps running, and does not retry that commit. The reason is in its logs. A new commit (a fix, or the revert) triggers a new attempt.
- **Doco-CD is gone** (container removed, volume lost): run the [bootstrap](bootstrap.md#3-bootstrap-of-doco-cd) again. The running stacks are not touched meanwhile; Doco-CD takes them back at its first poll.

## Rotating the token of Doco-CD

1. In the web interface of 1Password, open the service account `nas-doco-cd`: *Rotate token*, *Expire existing token: now*. Doco-CD cannot resolve the secrets until step 3; the running containers are not touched.
2. Paste the new token in the **existing** item `1password-doco-cd` (`infrastructure` vault), field `credential`.
3. Write the file again, from `ansible/`, then restart Doco-CD on the NAS: it reads the file at startup.

   ```sh
   opsa ansible-playbook --inventory=inventories/nas.yml nas.yml --diff
   ssh truenas_admin@nas-01.shelltopia.net sudo docker restart <container>
   ```

   Expected: the playbook changes the token file only; the next poll resolves the secrets, no 1Password error in the logs.

## After a TrueNAS upgrade

- [ ] **Checks:**

  ```sh
  sudo docker compose ls
  sudo docker ps --filter label=com.docker.compose.project=doco-cd
  sudo docker network ls --filter name=proxy
  sudo ls -l <dataset>/op-token
  ```

  Expected: every stack of `docker/nas-01` listed, Doco-CD `healthy`, the network `proxy` and the token file still there. Otherwise, the [bootstrap](bootstrap.md#3-bootstrap-of-doco-cd) again. Then `https://traefik.nas-01.shelltopia.net`: the macvlan depends on the name of `vlan14`.

- [ ] **Release notes** of TrueNAS: a change of Docker or Compose, of SSH or `sudo` for `truenas_admin`, of the Apps service, of the network interfaces.

## Rebuilding the NAS

1. TrueNAS installed, the pools imported or created, the datasets, SSH, the interface `vlan14`: by hand, in the web interface.
2. The [bootstrap](bootstrap.md#3-bootstrap-of-doco-cd) of Doco-CD. It deploys every stack of `docker/nas-01`, Traefik and Zerobyte included.
3. If the data of Zerobyte was lost: its first start and its SSO again ([bootstrap](bootstrap.md#5-zerobyte)), the provisioning with the new organization id and `isExistingRepository: true`, then the jobs from the [checklist](../backups/bootstrap.md#3-nas-data-zerobyte). Then the [restores](../backups/runbook.md#restores). Without Zerobyte, `restic` alone reads the repository with `restic-nas`.
