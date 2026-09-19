# Media dataset consolidation — runbook

Manual actions for the migration from nine media datasets to a single `vault/media` dataset with a standardized container mount convention.

This document covers everything **you** have to do by hand: TrueNAS, the vault-encrypted inventory, and application reconfiguration.

The mechanical codebase changes are specified separately in [`media-dataset-migration-codebase.md`](./media-dataset-migration-codebase.md), written to be handed to an agent.

## Goal

Every media folder is currently its own ZFS dataset. A dataset is a distinct filesystem, so any move between them (download → library) is a full copy and hardlinks are impossible. Consolidating into one dataset makes those operations `rename(2)`/`link(2)` — instant, with no duplicated data for seeding.

Alongside that, container bind mounts are standardized: every container sees the same absolute path for the same file.

## Target layout

Only `vault/media` is a dataset. Everything below is a plain directory.

```text
vault
└── media                     <- the only dataset
    ├── download
    │   ├── bittorrent        <- flat: category dirs directly here
    │   │   ├── audio
    │   │   ├── movies
    │   │   └── tv
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

Changes from the old layout, beyond the dataset collapse:

| Old | New | Note |
| --- | --- | --- |
| `downloads/bittorrent/downloads/*` | `download/bittorrent/*` | Intermediate level removed, category dirs move up. |
| `downloads/bittorrent/watch` | *(dropped)* | No watch folder. |
| `downloads/usenet/completed` | `download/usenet/complete` | Renamed. |
| `downloads/usenet/processing` | `download/usenet/incomplete` | Renamed. |
| `downloads/usenet/watching` | *(dropped)* | No watch folder. |
| `medias/*` | `library/*` | Renamed, now directories. |

## Container mount convention: `/mnt`

The host path maps one-to-one into the container, with `/mnt` standing in for `{{ storage_server_shares_mounts_path }}`:

```text
{{ storage_server_shares_mounts_path }}/media/library/movies   ->   /mnt/media/library/movies
```

`/mnt` is the right choice here. Application images routinely claim `/data` for their own state — Navidrome's `ND_DATAFOLDER` defaults to `/data`, and the current Navidrome quadlet already mounts its database there. Gitea, Grafana and many others do the same. `/mnt` is effectively never used by an application image, and the FHS defines it as the mount point for filesystems attached by an administrator, which is exactly what these are.

The only consequence is that Navidrome needs `ND_MUSICFOLDER` set explicitly, because its default is `/music`. Its own `/data` mount is left completely alone.

## Mount matrix

Hardlinks work across separate bind mounts as long as they resolve to the same underlying filesystem — which they do, since everything is now one NFS mount of one dataset. That means each container can be given several narrow mounts instead of one broad one, with no loss of functionality.

| Container | Mounts | Mode |
| --- | --- | --- |
| `transmission` | `/mnt/media/download/bittorrent` | rw |
| `unpackerr` | `/mnt/media/download/bittorrent` | rw |
| `sabnzbd` | `/mnt/media/download/usenet` | rw |
| `radarr` | `/mnt/media/download`, `/mnt/media/library/movies` | rw |
| `sonarr` | `/mnt/media/download`, `/mnt/media/library/tv` | rw |
| `lidarr` | `/mnt/media/download`, `/mnt/media/library/music` | rw |
| `mylar` | `/mnt/media/download`, `/mnt/media/library/comics` | rw |
| `cross_seed` | `/mnt/media/download`, `/mnt/media/library/tv` | rw |
| `bazarr` | `/mnt/media/library/movies`, `/mnt/media/library/tv` | rw |
| `muxarr` | `/mnt/media/library/movies`, `/mnt/media/library/tv` | rw |
| `uldas` | `/mnt/media/library/movies`, `/mnt/media/library/tv` | rw |
| `plex` | `/mnt/media/library/audiobooks`, `/mnt/media/library/audiodrama`, `/mnt/media/library/movies`, `/mnt/media/library/music`, `/mnt/media/library/tv` | **ro** |
| `navidrome` | `/mnt/media/library/music` | **ro** |
| `komga` | `/mnt/media/library/comics` | rw |
| `calibre` | `/mnt/media/library/books` | rw |
| `calibre_web` | `/mnt/media/library/books` | rw |

No container can reach a library category it does not manage. Plex gets five read-only mounts and cannot see `books` or `comics`. Transmission can only reach its own download tree.

### Optional further tightening

The \*arr apps get all of `/mnt/media/download` rather than only the specific category folders they import from. Narrowing further is possible — for example Radarr could take `download/bittorrent/movies` plus `download/usenet/complete` — but it couples the quadlet to the category folder names configured inside SABnzbd and inside each \*arr download client. Those are values I cannot verify from the repository.

If you want that, confirm the SABnzbd category folder names first and it is a small follow-up change. The current scoping already removes the meaningful risk, which was cross-library write access.

## Part 1 — TrueNAS

### 1.1 Create the dataset

`recordsize` only applies to newly written blocks, so it must be set **before** any data is copied in.

```sh
zfs create vault/media
zfs set recordsize=1M vault/media
zfs set atime=off vault/media
zfs set compression=lz4 vault/media
```

Use the **Generic** dataset preset in the UI (POSIX ACLs), not SMB or Multiprotocol. Verify:

```sh
zfs get recordsize,atime,compression,acltype,aclmode,xattr vault/media
```

Expected: `recordsize=1M`, `atime=off`, `acltype=posix`, `xattr=sa`.

Rationale for `recordsize=1M`: large write-once/read-many files, so fewer blocks, less metadata, far less RAIDZ padding overhead, faster scrub and resilver. Torrent write amplification is mitigated in practice because clients flush on piece boundaries and the records being filled stay hot in ARC.

Rationale for keeping `acltype=posix`: with `mapall` every NFS request is squashed to a single identity, so NFSv4 ACL granularity is never evaluated. NFSv4 ACLs are also a TrueNAS-specific extension on Linux — upstream OpenZFS states *"The `nfsv4` ZFS ACL type is not yet supported on Linux"* — which would break `setfacl`, `chmod` and `rsync -A`.

### 1.2 Create the skeleton

```sh
mkdir -p /mnt/vault/media/download/bittorrent/{tv,movies,audio}
mkdir -p /mnt/vault/media/download/usenet/{complete,incomplete}
mkdir -p /mnt/vault/media/library/{audiobooks,audiodrama,books,comics,movies,music,tv}
```

Apply the same ownership and modes as the existing datasets, using standard UNIX tools as you do today.

### 1.3 Drain the queues

Before copying, let the download queues finish or pause them:

- Let SABnzbd finish its queue. Anything left in `processing` is not worth migrating — it will be re-downloaded.
- Pause Transmission but do **not** remove torrents; their data moves and gets re-pointed in step 4.1.

### 1.4 First copy pass

Use `rsync`, **not** `zfs send | zfs receive` — send/receive preserves the original block layout and would keep the old 128K record size.

```sh
# Library
rsync -aAXH --info=progress2 /mnt/vault/medias/movies/     /mnt/vault/media/library/movies/
rsync -aAXH --info=progress2 /mnt/vault/medias/series/     /mnt/vault/media/library/tv/
rsync -aAXH --info=progress2 /mnt/vault/medias/music/      /mnt/vault/media/library/music/
rsync -aAXH --info=progress2 /mnt/vault/medias/books/      /mnt/vault/media/library/books/
rsync -aAXH --info=progress2 /mnt/vault/medias/comics/     /mnt/vault/media/library/comics/
rsync -aAXH --info=progress2 /mnt/vault/medias/audiobooks/ /mnt/vault/media/library/audiobooks/
rsync -aAXH --info=progress2 /mnt/vault/medias/audiodrama/ /mnt/vault/media/library/audiodrama/

# Downloads — note the flattening and the renames
rsync -aAXH --info=progress2 /mnt/vault/downloads/bittorrent/downloads/ /mnt/vault/media/download/bittorrent/
rsync -aAXH --info=progress2 /mnt/vault/downloads/usenet/completed/     /mnt/vault/media/download/usenet/complete/
```

`-H` preserves hardlinks that already exist inside a given source tree. `-A` preserves POSIX ACLs, which works precisely because `acltype=posix` is being kept.

`downloads/bittorrent/watch`, `downloads/usenet/processing` and `downloads/usenet/watching` are intentionally not copied.

### 1.5 Replace the NFS export

Replace the nine exports with **one** export of `/mnt/vault/media`, keeping the same `mapall` user and group.

> **Critical:** it must be a single export. Nine exports of subdirectories would be nine NFS mounts on the client with different `st_dev` values, and the \*arr apps would fall back to copying instead of hardlinking — defeating the entire migration. Multiple *bind* mounts of that single NFS mount are fine; multiple *NFS* mounts are not.

## Part 2 — Vault-encrypted inventory

`inventories/production.yml` is vault-encrypted, so only you can edit it. Run `make vault`.

The agent will make the equivalent change to `inventories/example.yml`; mirror it here.

**`medias` host** — replace all nine `storage_server_shares` entries:

```yaml
      storage_server_shares:
        - name: 'media'
```

**`backups` host** — replace the four `medias/*` entries, keep the `backups/*` ones:

```yaml
      storage_server_shares:
        - name: 'backups/documents'
        - name: 'backups/groupware'
        - name: 'backups/servers'
        - name: 'media'
```

## Part 3 — Cutover

1. **Stop the workloads.**

   ```sh
   make provision env=production limit=medias tags=containers-stop
   ```

   On the `backups` host, stop the borgmatic and autorestic timers so no backup fires mid-migration.

2. **Final delta sync.** Re-run every `rsync` command from step 1.4. This pass should be fast.

3. **Verify the copy.**

   ```sh
   diff <(cd /mnt/vault/medias && find . -type f | sort) \
        <(cd /mnt/vault/media/library && find . -type f | sort)
   du -sh /mnt/vault/medias /mnt/vault/media/library
   ```

4. **Switch the NFS export** (step 1.5) if not already done.

5. **Apply the codebase changes** (agent document) and your inventory edit, then deploy:

   ```sh
   make dry-run env=production limit=medias,backups
   make provision env=production limit=medias,backups
   ```

6. **Remove the stale systemd units.** `roles/fedora_coreos_setup/tasks/automount.yml` only ever creates units — it never removes them. The old ones will remain, fail on boot, and leave empty mount points behind.

   ```sh
   systemctl list-units --all --type=mount,automount 'var-mnt-*'
   sudo systemctl disable --now var-mnt-nas-medias-*.automount var-mnt-nas-downloads-*.automount
   sudo rm /etc/systemd/system/var-mnt-nas-medias-*.mount
   sudo rm /etc/systemd/system/var-mnt-nas-medias-*.automount
   sudo rm /etc/systemd/system/var-mnt-nas-downloads-*.mount
   sudo rm /etc/systemd/system/var-mnt-nas-downloads-*.automount
   sudo systemctl daemon-reload
   sudo rmdir /var/mnt/nas/medias/* /var/mnt/nas/medias
   sudo rmdir /var/mnt/nas/downloads/* /var/mnt/nas/downloads
   ```

   Repeat on the `backups` host for the four `var-mnt-nas-medias-*` units. Substitute the real value of `storage_server.name` for `nas`.

7. **Start the workloads.**

   ```sh
   make provision env=production limit=medias tags=containers-start
   ```

8. **Reconfigure the applications** — see Part 4. Nothing will work correctly until this is done.

## Part 4 — Application reconfiguration

Standardizing the in-container paths means **every application's stored paths change**. This is the real cost of the standardization and it cannot be automated from this repository — these values live in each application's own database.

Work through this list with the containers running.

### 4.1 Transmission

The managed `settings.json` keys are applied automatically by the new custom-init script on container start. Verify:

```sh
sudo podman exec transmission jq '."download-dir", ."watch-dir-enabled", ."cache-size-mb"' /config/settings.json
```

Expected: `"/mnt/media/download/bittorrent"`, `false`, `256`.

**Re-point every existing torrent.** Transmission stores an absolute path per torrent in its resume files, so all of them now point at a path that no longer exists. Use `--find`, which relocates without moving data:

```sh
sudo podman exec transmission transmission-remote \
  --auth USER:PASS -t all --find /mnt/media/download/bittorrent
```

Because the category folders (`tv`, `movies`, `audio`) moved up one level rather than disappearing, `--find` pointed at the `bittorrent` root will resolve each torrent's data correctly. Verify on a single torrent before running it against `all`, then force a recheck on a couple and confirm they return to seeding rather than "No data found".

### 4.2 SABnzbd

Settings → Folders:

- Temporary Download Folder: `/mnt/media/download/usenet/incomplete`
- Completed Download Folder: `/mnt/media/download/usenet/complete`
- Watched Folder: **clear it** (the watch folder is gone).

### 4.3 Radarr / Sonarr / Lidarr / Mylar

For each, in order:

1. Settings → Media Management → Root Folders: add the new root, for example `/mnt/media/library/movies`.
2. Library → select all → Mass Editor → Root Folder → the new root → **answer "No" when asked whether to move the files** (they are already in place).
3. Remove the old root folder.
4. Settings → Download Clients → edit the Transmission client: set the directory to `/mnt/media/download/bittorrent/<category>` (`tv`, `movies`, `audio`).
5. Settings → Download Clients → edit the SABnzbd client if the category paths were overridden.
6. Settings → Download Clients → **delete any Remote Path Mappings.** They are no longer needed — the download client and the \*arr app now report identical absolute paths. This is the main ergonomic win of the standardization.
7. Settings → Media Management → enable **Use Hardlinks instead of Copy**. This was previously ineffective across datasets and is the main payoff of the migration.

### 4.4 Plex

Each library's folders must be repointed:

| Library | Old | New |
| --- | --- | --- |
| Movies | `/data/movies` | `/mnt/media/library/movies` |
| TV | `/data/series` | `/mnt/media/library/tv` |
| Music | `/data/music` | `/mnt/media/library/music` |
| Audiobooks | `/data/audiobooks` | `/mnt/media/library/audiobooks` |
| Audiodrama | `/data/audiodrama` | `/mnt/media/library/audiodrama` |

Add the new folder first, let it scan, then remove the old one — that way Plex matches by file rather than discarding watch state. Verify watched status and collections afterwards.

### 4.5 Navidrome

`ND_MUSICFOLDER` is set in the quadlet by the agent, and Navidrome's own `/data` mount is untouched. On first start it will re-scan because the music path changed. Confirm the existing database was found — not a fresh empty library — and that play counts and playlists survived:

```sh
sudo podman logs navidrome | head -40
```

### 4.6 Komga, Calibre, Calibre-Web

- **Komga:** Libraries → edit → root path `/mnt/media/library/comics`.
- **Calibre:** the library path moves to `/mnt/media/library/books`. Open the desktop UI and use *Calibre Library → Switch/create library* to point at the new path.
- **Calibre-Web:** Admin → Configuration → Calibre Database Directory: `/mnt/media/library/books`.

### 4.7 Bazarr, Muxarr, Uldas, cross-seed

- **Bazarr:** it reads paths from Sonarr/Radarr, so once those are updated, run Settings → Sonarr/Radarr → *Sync* and then a full disk scan. Delete any path mappings.
- **cross-seed:** update `dataDirs`, `torrentDir` and `linkDir` in its config to the `/mnt/media/...` equivalents.
- **Muxarr / Uldas:** update whatever path configuration each holds to `/mnt/media/library/...`.

## Part 5 — Validation

```sh
# One NFS mount, not nine
findmnt -t nfs4 -o TARGET,SOURCE,OPTIONS

# rsize/wsize should be 1048576, matching recordsize=1M
findmnt -t nfs4 -o TARGET,OPTIONS | grep media

# Dataset properties took effect
zfs get recordsize,atime,compression,acltype,xattr vault/media

# Everything is one filesystem — the device number must match
stat -c '%d %n' /var/mnt/nas/media/download/bittorrent /var/mnt/nas/media/library/tv

# Hardlinks actually work across the tree
touch /var/mnt/nas/media/download/bittorrent/.linktest
ln /var/mnt/nas/media/download/bittorrent/.linktest \
   /var/mnt/nas/media/library/tv/.linktest \
  && echo HARDLINK_OK
rm -f /var/mnt/nas/media/download/bittorrent/.linktest \
      /var/mnt/nas/media/library/tv/.linktest

# No failed units left behind
systemctl --failed
```

Then, functionally:

- Import a test release in Radarr and confirm it is instantaneous and that `zfs list vault/media` does **not** grow by the size of the file. That proves hardlinking works across the two separate bind mounts.
- Confirm Transmission is still seeding everything after the `--find`.
- Play one item from each Plex library.
- Trigger a manual borgmatic run on the `backups` host and confirm it completes.

## Part 6 — Retire the old datasets

Only after a soak period — a week of successful backups, imports and playback is a reasonable bar.

```sh
zfs set readonly=on vault/medias
zfs set readonly=on vault/downloads
# ... soak ...
zfs destroy -r vault/medias
zfs destroy -r vault/downloads
```

## Rollback

Until Part 6, rollback is cheap because the old datasets are untouched:

1. `git revert` the migration commit.
2. Restore the nine NFS exports on TrueNAS.
3. Revert the inventory change with `make vault`.
4. `make provision env=production limit=medias,backups`.
5. Re-point Transmission back with `transmission-remote -t all --find /downloads`.
6. Restore the \*arr root folders and Plex library paths.

Anything downloaded into `media/` after the cutover must be copied back manually, so keep the soak period short — and be aware that Part 4 is a fair amount of work to undo. The point of no return is practical, not technical.

## Impact on backups

`borgmatic` and `autorestic` record absolute paths. After this migration, new snapshots use the new paths while old snapshots keep the old ones.

Both tools deduplicate by content, so **no data will be re-uploaded** — only new file metadata. But restores from pre-migration snapshots will land under the old paths. Note the cutover date somewhere you will find it later.

## Decisions and open questions

- **`download` (singular).** Your target layout uses the singular while the old tree used `downloads`. Renaming is free now and expensive once everything has been reconfigured against it — worth a deliberate confirmation.
- **The `medias` host name.** The Ansible host is also called `medias` (inventory, `provision.yml`, `Makefile` examples). Unrelated to the dataset and deliberately left alone, but it will read slightly inconsistently afterwards.
- **The `medias` backup set name.** `borgmatic`/`autorestic` use `medias` as a *backup set* name, not a path: `medias.yaml.j2`, the `borgmatic_medias_encryption_passphrase` podman secret, the `borgbase-medias` repository label, and the `borgmatic.medias.*` / `autorestic.medias.*` inventory keys. Renaming would mean rotating a secret and relabelling an existing borg repository, so it is out of scope.
- **Backups host mounts are not standardized.** `borgmatic` and `autorestic` deliberately bind host paths onto the identical path inside the container, so that borg archives contain real host paths. They keep that convention; only the media path changes and the four mounts collapse to one. If you want them on `/mnt` too, that is a separate change that would also touch the `backups/*` mounts.
