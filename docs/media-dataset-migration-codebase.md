# Media dataset consolidation — codebase task

Task specification for an agent. Self-contained: everything needed is below, no prior conversation required.

The human-side runbook (TrueNAS, vaulted inventory, application reconfiguration) lives in [`media-dataset-migration.md`](./media-dataset-migration.md) and is **not** your responsibility.

## Objective

The NAS is collapsing nine ZFS datasets into a single `vault/media` dataset, exported over NFS as one share named `media`. At the same time, every container's media bind mounts are being standardized.

Your job is to update this Ansible repository to match. This is a mechanical, well-specified refactor. Do not improvise beyond what is written here.

## Hard constraints

- **Do not edit `inventories/production.yml`.** It is vault-encrypted and handled by the repository owner. Only `inventories/example.yml` is in scope.
- **Do not run `ansible-playbook`, `make provision`, `make dry-run`, or any deployment command.**
- **Do not change container-internal paths other than those specified below.** In particular leave `/config`, `/data`, `/tmp`, `/transcode`, `/app/config` and all `{{ containers_storage_path }}` mounts alone.
- **Do not add `:Z` or `:z` to the NFS-backed volumes.** They use `:slave` propagation and rely on the `virt_use_nfs` SELinux boolean, already handled by `roles/podman_setup/tasks/storage.yml`.
- **Preserve the existing line position.** Where several `Volume=` lines are replaced, put the new lines where the old block was, in the order given.
- **Preserve the repository's YAML style:** single-quoted scalars, two-space indentation, `---` document start.
- Keep changes minimal and focused. Do not reformat unrelated lines.

## The convention

The host path maps one-to-one into the container, with `/mnt` standing in for `{{ storage_server_shares_mounts_path }}`:

```text
{{ storage_server_shares_mounts_path }}/media/library/movies   ->   /mnt/media/library/movies
```

`/mnt` is used rather than `/data` because application images frequently claim `/data` for their own state — Navidrome's is the concrete case in this repository.

Each container gets the **narrowest set of mounts** covering only what it needs. Multiple mounts are fine: hardlinks still work across them because they all resolve to the same NFS superblock.

New host-side directory layout, for reference only — you are not creating it:

```text
media
├── download
│   ├── bittorrent          <- category dirs (tv, movies, audio) directly here
│   └── usenet
│       ├── complete
│       └── incomplete
└── library
    ├── audiobooks
    ├── audiodrama
    ├── books
    ├── comics
    ├── movies
    ├── music
    └── tv
```

Renames: `downloads` → `media/download`, `medias` → `media/library`, the `bittorrent/downloads` and `bittorrent/watch` level is gone, `usenet/completed` → `usenet/complete`, `usenet/processing` → `usenet/incomplete`, `usenet/watching` is gone.

## Change 1 — `inventories/example.yml`

### 1a. `medias` host (around line 336)

Replace:

```yaml
      storage_server_shares:
        - name: 'downloads/bittorrent'
        - name: 'downloads/usenet'
        - name: 'medias/audiobooks'
        - name: 'medias/audiodrama'
        - name: 'medias/books'
        - name: 'medias/comics'
        - name: 'medias/movies'
        - name: 'medias/music'
        - name: 'medias/series'
```

With:

```yaml
      storage_server_shares:
        - name: 'media'
```

### 1b. `backups` host (around line 59)

Replace:

```yaml
      storage_server_shares:
        - name: 'backups/documents'
        - name: 'backups/groupware'
        - name: 'backups/servers'
        - name: 'medias/audiobooks'
        - name: 'medias/audiodrama'
        - name: 'medias/books'
        - name: 'medias/comics'
```

With:

```yaml
      storage_server_shares:
        - name: 'backups/documents'
        - name: 'backups/groupware'
        - name: 'backups/servers'
        - name: 'media'
```

## Change 2 — `roles/fedora_coreos_setup/templates/systemd.mount.j2`

Add an explicit NFS transfer size matching the new `recordsize=1M`, so a record is not split across multiple RPCs.

Replace:

```jinja
{% if storage_server.type == "cifs" %}
Options=seal,credentials=/etc/smbcredentials,iocharset=utf8,uid={{ item.uid }},gid={{ item.gid }},file_mode=0640,dir_mode=0750
{% endif %}
```

With:

```jinja
{% if storage_server.type == "cifs" %}
Options=seal,credentials=/etc/smbcredentials,iocharset=utf8,uid={{ item.uid }},gid={{ item.gid }},file_mode=0640,dir_mode=0750
{% elif storage_server.type == "nfs" %}
Options=rsize=1048576,wsize=1048576
{% endif %}
```

## Change 3 — Container quadlets on the `medias` host

For each file, delete the listed `Volume=` lines and insert the replacement block at the position of the first deleted line.

### `roles/bazarr/templates/bazarr.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/movies:/movies:slave
Volume={{ storage_server_shares_mounts_path }}/medias/series:/tv:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/movies:/mnt/media/library/movies:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/tv:/mnt/media/library/tv:slave
```

### `roles/calibre/templates/calibre.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/books:/books:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/books:/mnt/media/library/books:slave
```

### `roles/calibre_web/templates/calibre-web.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/books:/books:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/books:/mnt/media/library/books:slave
```

### `roles/cross_seed/templates/cross-seed.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads:/downloads:slave
Volume={{ storage_server_shares_mounts_path }}/medias/series:/tv:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download:/mnt/media/download:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/tv:/mnt/media/library/tv:slave
```

### `roles/komga/templates/komga.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/comics:/books:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/comics:/mnt/media/library/comics:slave
```

### `roles/lidarr/templates/lidarr.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads:/downloads:slave
Volume={{ storage_server_shares_mounts_path }}/medias/music:/music:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download:/mnt/media/download:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/music:/mnt/media/library/music:slave
```

### `roles/muxarr/templates/muxarr.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/movies:/movies:slave
Volume={{ storage_server_shares_mounts_path }}/medias/series:/tv:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/movies:/mnt/media/library/movies:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/tv:/mnt/media/library/tv:slave
```

### `roles/mylar/templates/mylar.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads:/downloads:slave
Volume={{ storage_server_shares_mounts_path }}/medias/comics:/comics:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download:/mnt/media/download:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/comics:/mnt/media/library/comics:slave
```

### `roles/plex/templates/plex.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/audiobooks:/data/audiobooks:slave,ro
Volume={{ storage_server_shares_mounts_path }}/medias/audiodrama:/data/audiodrama:slave,ro
Volume={{ storage_server_shares_mounts_path }}/medias/movies:/data/movies:slave,ro
Volume={{ storage_server_shares_mounts_path }}/medias/music:/data/music:slave,ro
Volume={{ storage_server_shares_mounts_path }}/medias/series:/data/series:slave,ro
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/audiobooks:/mnt/media/library/audiobooks:slave,ro
Volume={{ storage_server_shares_mounts_path }}/media/library/audiodrama:/mnt/media/library/audiodrama:slave,ro
Volume={{ storage_server_shares_mounts_path }}/media/library/movies:/mnt/media/library/movies:slave,ro
Volume={{ storage_server_shares_mounts_path }}/media/library/music:/mnt/media/library/music:slave,ro
Volume={{ storage_server_shares_mounts_path }}/media/library/tv:/mnt/media/library/tv:slave,ro
```

### `roles/radarr/templates/radarr.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads:/downloads:slave
Volume={{ storage_server_shares_mounts_path }}/medias/movies:/movies:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download:/mnt/media/download:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/movies:/mnt/media/library/movies:slave
```

### `roles/sabnzbd/templates/sabnzbd.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads/usenet/completed:/downloads:slave
Volume={{ storage_server_shares_mounts_path }}/downloads/usenet/processing:/incomplete-downloads:slave
Volume={{ storage_server_shares_mounts_path }}/downloads/usenet/watching:/watching:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download/usenet:/mnt/media/download/usenet:slave
```

### `roles/sonarr/templates/sonarr.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads:/downloads:slave
Volume={{ storage_server_shares_mounts_path }}/medias/series:/tv:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download:/mnt/media/download:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/tv:/mnt/media/library/tv:slave
```

### `roles/uldas/templates/uldas.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/movies:/movies:slave
Volume={{ storage_server_shares_mounts_path }}/medias/series:/tv:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/movies:/mnt/media/library/movies:slave
Volume={{ storage_server_shares_mounts_path }}/media/library/tv:/mnt/media/library/tv:slave
```

## Change 4 — `roles/navidrome/templates/navidrome.container.j2`

Navidrome's own `/data` mount is **left alone**. Only the music volume changes, plus one new environment variable, because Navidrome's `ND_MUSICFOLDER` defaults to `/music`.

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/medias/music:/music:slave,ro
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/library/music:/mnt/media/library/music:slave,ro
```

Then, immediately after the existing `ND_BASEURL` line, add:

```ini
Environment="ND_MUSICFOLDER=/mnt/media/library/music"
```

Do **not** touch `Volume={{ containers_storage_path }}/data/navidrome:/data:Z`.

## Change 5 — `roles/unpackerr/templates/unpackerr.container.j2`

Both the volume and the three path environment variables change. The `UN_*_PATHS_0` values must match what Sonarr/Radarr/Lidarr report, which is now the standardized path.

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads/bittorrent/downloads:/downloads/bittorrent/downloads:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download/bittorrent:/mnt/media/download/bittorrent:slave
```

Replace the three path lines:

```ini
Environment="UN_SONARR_0_PATHS_0=/downloads/bittorrent/downloads/tv"
Environment="UN_RADARR_0_PATHS_0=/downloads/bittorrent/downloads/movies"
Environment="UN_LIDARR_0_PATHS_0=/downloads/bittorrent/downloads/audio"
```

With:

```ini
Environment="UN_SONARR_0_PATHS_0=/mnt/media/download/bittorrent/tv"
Environment="UN_RADARR_0_PATHS_0=/mnt/media/download/bittorrent/movies"
Environment="UN_LIDARR_0_PATHS_0=/mnt/media/download/bittorrent/audio"
```

Leave the `UN_*_URL` and `UN_*_PROTOCOLS` lines untouched.

## Change 6 — Transmission role

Four edits plus one new file. This adds Ansible-managed `settings.json` keys, which the LinuxServer image does not expose as environment variables.

Background needed to get this right: the image is s6-overlay v3 and ships `jq`. `/custom-cont-init.d` scripts run after the image's own `init-transmission-config` (so `settings.json` already exists) and before `transmission-daemon` starts. Scripts **must** be executable or the image logs `is not an executable file` and skips them.

### 6a. `roles/transmission/templates/transmission.container.j2`

Delete:

```ini
Volume={{ storage_server_shares_mounts_path }}/downloads/bittorrent/downloads:/downloads:slave
Volume={{ storage_server_shares_mounts_path }}/downloads/bittorrent/watch:/watch:slave
```

Insert:

```ini
Volume={{ storage_server_shares_mounts_path }}/media/download/bittorrent:/mnt/media/download/bittorrent:slave
Volume={{ containers_storage_path }}/data/transmission-custom-init:/custom-cont-init.d:ro,Z
```

### 6b. `roles/transmission/defaults/main.yml`

Append to the file:

```yaml

# settings.json keys not exposed as environment variables by the LinuxServer
# image. Deep-merged into settings.json on every container start.
# Do not set rpc-* keys here, they are managed via the image's env vars.
transmission_settings:
  cache-size-mb: 256
  download-dir: '/mnt/media/download/bittorrent'
  incomplete-dir-enabled: false
  preallocation: 1
  watch-dir-enabled: false
```

### 6c. New file `roles/transmission/templates/transmission-settings.sh.j2`

```bash
#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Managed by Ansible - roles/transmission

SETTINGS='/config/settings.json'

if [[ ! -f "${SETTINGS}" ]]; then
    echo 'transmission-settings: settings.json not found, skipping'
    exit 0
fi

OVERRIDES=$(cat <<'JSON'
{{ transmission_settings | to_nice_json }}
JSON
)

if PATCHED=$(jq --argjson overrides "${OVERRIDES}" '. * $overrides' "${SETTINGS}"); then
    # Truncate in place so the abc:abc ownership set by init-transmission-config is preserved.
    printf '%s\n' "${PATCHED}" >"${SETTINGS}"
    echo 'transmission-settings: applied Ansible-managed settings'
else
    echo 'transmission-settings: jq failed, settings.json left untouched' >&2
fi
```

### 6d. `roles/transmission/tasks/create.yml`

Add a new entry to the loop of the existing task `Create Transmission pod bind mounts paths`, after the `data/transmission` entry:

```yaml
    - path: 'data/transmission-custom-init'
      owner: 'root'
      group: 'root'
```

Insert a new task immediately **before** the task named `Create Transmission pod quadlet units from templates`:

```yaml
- name: 'Create Transmission custom init script from template'
  ansible.builtin.template:
    src: 'transmission-settings.sh.j2'
    dest: '{{ containers_storage_path }}/data/transmission-custom-init/transmission-settings.sh'
    owner: 'root'
    group: 'root'
    mode: '0755'
  register: 'transmission_settings_script'
```

Finally, widen the condition of the last task, `Restart Transmission pod if any systemd unit has changed while pod was already started`:

```yaml
  when: ((quadlet_units.changed or transmission_settings_script.changed) and not systemd_start.changed)
```

## Change 7 — Backup roles on the `backups` host

`borgmatic` and `autorestic` deliberately bind host paths onto the **identical** path inside the container so that archives contain real host paths. **Keep that convention** — do not apply the `/mnt` mapping here. Only the media path changes, and the four media mounts collapse into one.

### 7a. Volume lines

In each of these files:

- `roles/autorestic/templates/autorestic.j2`
- `roles/autorestic/templates/autorestic.service.j2`
- `roles/borgmatic/templates/borgmatic-shell.j2`
- `roles/borgmatic/templates/borgmatic.j2`
- `roles/borgmatic/templates/borgmatic.service.j2`

Replace the four consecutive media `--volume` lines with a single line. Preserve each file's existing leading whitespace, trailing backslash, and `:slave` / `:slave,ro` suffix exactly as the surrounding lines use them.

For example, in `borgmatic.j2` the four lines:

```sh
--volume {{ storage_server_shares_mounts_path }}/medias/audiodrama:{{ storage_server_shares_mounts_path }}/medias/audiodrama:slave \
--volume {{ storage_server_shares_mounts_path }}/medias/audiobooks:{{ storage_server_shares_mounts_path }}/medias/audiobooks:slave \
--volume {{ storage_server_shares_mounts_path }}/medias/books:{{ storage_server_shares_mounts_path }}/medias/books:slave \
--volume {{ storage_server_shares_mounts_path }}/medias/comics:{{ storage_server_shares_mounts_path }}/medias/comics:slave \
```

become:

```sh
--volume {{ storage_server_shares_mounts_path }}/media/library:{{ storage_server_shares_mounts_path }}/media/library:slave \
```

In `autorestic.service.j2` and `borgmatic.service.j2` the equivalent lines sit inside the `ExecStart` block, are indented with a leading hard tab, and use `:slave,ro`. Keep both the tab and the `,ro`.

### 7b. `RequiresMountsFor` lines

In `roles/autorestic/templates/autorestic.service.j2` and `roles/borgmatic/templates/borgmatic.service.j2`, replace:

```ini
RequiresMountsFor={{ storage_server_shares_mounts_path }}/medias/audiodrama
RequiresMountsFor={{ storage_server_shares_mounts_path }}/medias/audiobooks
RequiresMountsFor={{ storage_server_shares_mounts_path }}/medias/books
RequiresMountsFor={{ storage_server_shares_mounts_path }}/medias/comics
```

With:

```ini
RequiresMountsFor={{ storage_server_shares_mounts_path }}/media/library
```

Leave the `backups/documents`, `backups/groupware` and `backups/servers` lines untouched.

### 7c. Backup source lists

Keep these **explicit and unchanged in number** — do not collapse them to `media/library`, or movies, tv and the download tree would be pushed to the offsite repository.

In `roles/borgmatic/templates/medias.yaml.j2`, replace the `source_directories` block with:

```yaml
source_directories:
  - '{{ storage_server_shares_mounts_path }}/media/library/audiodrama'
  - '{{ storage_server_shares_mounts_path }}/media/library/audiobooks'
  - '{{ storage_server_shares_mounts_path }}/media/library/books'
  - '{{ storage_server_shares_mounts_path }}/media/library/comics'
```

In `roles/autorestic/templates/autorestic.yml.j2`, apply the same replacement to the `from:` list of the `medias` location.

Do **not** rename the `medias` backup set itself. The name is also used for the podman secret `borgmatic_medias_encryption_passphrase`, the `borgbase-medias` repository label, the template filename `medias.yaml.j2`, and the `borgmatic.medias.*` / `autorestic.medias.*` inventory keys. Renaming would require rotating a secret and relabelling an existing borg repository, which is out of scope.

## Expected end state

Per-container media mounts after your changes:

| Container | Mounts | Count |
| --- | --- | --- |
| `bazarr` | `library/movies`, `library/tv` | 2 |
| `calibre` | `library/books` | 1 |
| `calibre_web` | `library/books` | 1 |
| `cross_seed` | `download`, `library/tv` | 2 |
| `komga` | `library/comics` | 1 |
| `lidarr` | `download`, `library/music` | 2 |
| `muxarr` | `library/movies`, `library/tv` | 2 |
| `mylar` | `download`, `library/comics` | 2 |
| `navidrome` | `library/music` (ro) | 1 |
| `plex` | `library/{audiobooks,audiodrama,movies,music,tv}` (ro) | 5 |
| `radarr` | `download`, `library/movies` | 2 |
| `sabnzbd` | `download/usenet` | 1 |
| `sonarr` | `download`, `library/tv` | 2 |
| `transmission` | `download/bittorrent` | 1 |
| `uldas` | `library/movies`, `library/tv` | 2 |
| `unpackerr` | `download/bittorrent` | 1 |

Total: **28** media `Volume=` lines across the container quadlets.

## Verification

These must return **no output**:

```sh
grep -rn 'storage_server_shares_mounts_path }}/medias' roles/
grep -rn 'storage_server_shares_mounts_path }}/downloads' roles/
grep -rn "name: 'medias/" inventories/example.yml
grep -rn "name: 'downloads/" inventories/example.yml
```

No stale container-internal media paths may remain — this must also return nothing:

```sh
grep -rnE ':/(movies|tv|music|books|comics|downloads|watch|watching|incomplete-downloads)(:|$)' \
  roles/*/templates/*.container.j2
```

This must report `28`:

```sh
grep -rhc 'storage_server_shares_mounts_path }}/media' roles/*/templates/*.container.j2 \
  | paste -sd+ | bc
```

Every media volume must map host path to the identical `/mnt`-prefixed path. Spot-check that each line matches the shape `.../media/<X>:/mnt/media/<X>:slave`:

```sh
grep -rn 'storage_server_shares_mounts_path }}/media' roles/*/templates/*.container.j2
```

Also confirm:

- `roles/transmission/templates/transmission-settings.sh.j2` exists.
- `roles/navidrome/templates/navidrome.container.j2` still contains `:/data:Z` and now also contains `ND_MUSICFOLDER`.
- `roles/transmission/tasks/create.yml` parses as valid YAML and the new task precedes the quadlet template task.

Run the repository's linters if available:

```sh
yamllint -c .yamllint.yml .
ansible-lint
```

`.markdownlint.yml` disables MD013 only, so avoid hard tabs in any Markdown you touch.

## Out of scope

- Editing `inventories/production.yml` (vault-encrypted).
- Creating, moving or deleting anything on the NAS or on any host.
- Running deployment commands.
- Renaming the `medias` Ansible host, the `medias` backup set, or `medias.yaml.j2`.
- Applying the `/mnt` convention to the `backups/*` mounts in the borgmatic and autorestic roles.
- Changing Navidrome's `/data` config mount.
- Adding cleanup tasks for stale systemd mount units — handled manually in the runbook.
- Modifying anything in `docs/`.

## Summary of files touched

| File | Change |
| --- | --- |
| `inventories/example.yml` | Collapse `storage_server_shares` on two hosts |
| `roles/fedora_coreos_setup/templates/systemd.mount.j2` | Add NFS `Options=` |
| `roles/bazarr/templates/bazarr.container.j2` | 2 volumes repathed |
| `roles/calibre/templates/calibre.container.j2` | 1 volume repathed |
| `roles/calibre_web/templates/calibre-web.container.j2` | 1 volume repathed |
| `roles/cross_seed/templates/cross-seed.container.j2` | 2 volumes repathed |
| `roles/komga/templates/komga.container.j2` | 1 volume repathed |
| `roles/lidarr/templates/lidarr.container.j2` | 2 volumes repathed |
| `roles/muxarr/templates/muxarr.container.j2` | 2 volumes repathed |
| `roles/mylar/templates/mylar.container.j2` | 2 volumes repathed |
| `roles/navidrome/templates/navidrome.container.j2` | 1 volume repathed, `ND_MUSICFOLDER` added |
| `roles/plex/templates/plex.container.j2` | 5 volumes repathed |
| `roles/radarr/templates/radarr.container.j2` | 2 volumes repathed |
| `roles/sabnzbd/templates/sabnzbd.container.j2` | 3 volumes → 1 |
| `roles/sonarr/templates/sonarr.container.j2` | 2 volumes repathed |
| `roles/uldas/templates/uldas.container.j2` | 2 volumes repathed |
| `roles/unpackerr/templates/unpackerr.container.j2` | 1 volume repathed, 3 env vars repathed |
| `roles/transmission/templates/transmission.container.j2` | 2 volumes → 1, plus custom-init volume |
| `roles/transmission/defaults/main.yml` | New `transmission_settings` dict |
| `roles/transmission/templates/transmission-settings.sh.j2` | **New file** |
| `roles/transmission/tasks/create.yml` | New bind mount path, new template task, widened restart condition |
| `roles/autorestic/templates/autorestic.j2` | 4 volumes → 1 |
| `roles/autorestic/templates/autorestic.service.j2` | 4 volumes → 1, 4 `RequiresMountsFor` → 1 |
| `roles/autorestic/templates/autorestic.yml.j2` | 4 source paths repathed |
| `roles/borgmatic/templates/borgmatic-shell.j2` | 4 volumes → 1 |
| `roles/borgmatic/templates/borgmatic.j2` | 4 volumes → 1 |
| `roles/borgmatic/templates/borgmatic.service.j2` | 4 volumes → 1, 4 `RequiresMountsFor` → 1 |
| `roles/borgmatic/templates/medias.yaml.j2` | 4 source paths repathed |
