# OpenTofu

| Stack | Content | Provider credentials (`infrastructure` vault) |
| --- | --- | --- |
| `cloudflare` | DNS records of `shelltopia.net` and `shelltopia.org` not managed from the cluster ([ingress.md](../docs/ingress.md#dns)), SSL mode, Universal SSL and DNSSEC of the zones ([Cloudflare](#cloudflare)), applied. | `cloudflare-tofu` |
| `backblaze` | B2 buckets and application keys of the restic repositories ([docs/backups](../docs/backups/README.md#destination-backblaze-b2)), pushed to 1Password. | `backblaze-b2-tofu-admin` |

| Recipe | What it does |
| --- | --- |
| `just tofu init <stack>` | Backend (`backend.hcl`), providers, lock file. Add `-reconfigure` after a change of `backend.hcl`. |
| `just tofu plan <stack>` | Shows the changes. |
| `just tofu apply <stack>` | Applies them, then runs `sync-1password`. |
| `just tofu sync-1password <stack>` | Creates or updates the 1Password items listed in the `onepassword_items` output of the stack, if any. |
| `just tofu run <stack> <arguments>` | Any tofu command, e.g. `just tofu run backblaze state list`. |

The recipes resolve `op.env` (backend and state encryption) and `<stack>/op.env` (provider credentials) with the workstation service account ([1password-local-access.md](../docs/1password-local-access.md)): no approval, and each stack only gets its own provider credentials.

## State

- One object per stack, `<stack>/terraform.tfstate`, in the B2 bucket `infrastructure-tofu-state-gz8j9y`, through the S3 backend (`backend.hcl`).
- **Encrypted on the client side** (`encryption` block of each stack, PBKDF2 and AES-GCM, plans included): B2 only stores ciphertext. Passphrase: `password` field of `infrastructure/tofu-state-encryption`. If it is lost, the states are unreadable and every resource has to be imported again.
- **The bucket is created by hand**, outside OpenTofu: no stack can destroy its own backend.
- **Its application key cannot delete file versions** (no `deleteFiles`): a new state or a lock release only hides the previous version. A lifecycle rule deletes the hidden versions after 90 days, so the replaced states are kept 90 days ([recovery](#restoring-a-previous-state)).
- Not in Git anymore: no commit to forget after an `apply`, no state diverging between branches, no secrets (application keys) kept forever in the history, even encrypted.
- B2 bucket names are global to all accounts: every bucket of the repository ends with the same random suffix, `gz8j9y`.

### Locking

None. The native S3 locking (`use_lockfile`) writes a `<key>.tflock` object with a conditional write (`If-None-Match`), which B2 does not implement: tested on 2026-10-25, `PutObject` fails with *501 NotImplemented: A header you provided implies functionality that is not implemented*. Hence `use_lockfile = false` in `backend.hcl`: there is a single operator, running two commands on the same stack at once is the only risk. To try again if B2 adds conditional writes: `use_lockfile = true`, then `just tofu init <stack> -reconfigure` for each stack, and a second `just tofu plan <stack>` while an `apply` waits at its confirmation prompt must stop with *Error acquiring the state lock*.

## Setup

Once, with the B2 CLI ([b2](https://www.backblaze.com/docs/cloud-storage-command-line-tools), installed by mise from PyPI) authorized with the master key (`b2 account authorize`).

- [x] Bucket of the states and its key:

  ```sh
  b2 bucket create infrastructure-tofu-state-gz8j9y allPrivate \
    --lifecycle-rule '{"daysFromHidingToDeleting": 90, "daysFromUploadingToHiding": null, "fileNamePrefix": ""}'
  b2 key create --bucket infrastructure-tofu-state-gz8j9y infrastructure-tofu-state listBuckets,listFiles,readFiles,writeFiles
  ```

- [x] 1Password, `infrastructure` vault, "Password" item `tofu-state-encryption`: `password` (generated, **at least 16 characters**, minimum of PBKDF2) and "API Credential" item `backblaze-b2-tofu-state`: `access-key-id` as username and `secret-access-key` as credential (the keyID and the key printed above).
- [x] Admin key of the `backblaze` stack, for the whole account (buckets, lifecycle rules, keys), **without `deleteFiles` nor `deleteBuckets`**: OpenTofu cannot delete a backup nor a bucket by mistake. This does not protect against a stolen key, see the escalation test below.

  ```sh
  b2 key create infrastructure-tofu-admin listBuckets,readBuckets,writeBuckets,readBucketEncryption,readBucketLifecycleRules,writeBucketLifecycleRules,readBucketInfo,writeBucketInfo,readBucketType,writeBucketType,readBucketCors,writeBucketCors,readBucketRetentions,listKeys,writeKeys,deleteKeys
  ```

  The exact list needed by the provider is not documented: if an `apply` fails with an `unauthorized` error, add the missing capability (a new key: capabilities cannot be changed).
- [x] 1Password, `infrastructure` vault, "API credential" item `backblaze-b2-tofu-admin`: `access-key-id` as username and `secret-access-key` as credential.
- [x] Escalation test, done on 2026-10-25: the admin key **can** create a key with `deleteFiles`. B2 does not limit the capabilities of a new key to those of the key creating it, and the new key deleted a file version of the state bucket for good. Accepted ([docs/backups](../docs/backups/README.md#protection-against-ransomware-and-stolen-keys)). The new key did not show in the web interface: list the keys with `b2 key list --long`. To redo:

  ```sh
  b2 account authorize   # with the admin key
  b2 key create --bucket infrastructure-tofu-state-gz8j9y escalation-test listBuckets,listFiles,deleteFiles   # the CLI needs listBuckets
  b2 key delete <keyID>  # then `b2 account clear`
  ```

- [x] `just tofu init backblaze` and commit `.terraform.lock.hcl` if it changed.
- [x] Lock test: the first `just tofu apply backblaze` failed with *501 NotImplemented*, locking disabled ([locking](#locking)), then `just tofu init backblaze -reconfigure`.
- [x] `just tofu apply backblaze`, answer `yes`: buckets and keys are created, then `sync-1password` creates the item `restic-volsync` (`kubernetes` vault, generated `password`) and fills `repository`, `access-key-id` and `secret-access-key`. One 1Password approval for each creation and each update ([pushing to 1Password](#pushing-to-1password)). Done on 2026-10-25: `host-spawn` forwards the standard input to `op item edit`.
- [x] `just tofu plan backblaze` shows no change, `just tofu sync-1password backblaze` says *Up to date* for each item.
- [x] `b2 account clear` if the CLI still holds the master key: it is never stored.

## Pushing to 1Password

The workstation service account is read-only. `sync-1password` uses it to find the items and compare their values. The writes go through the personal account (`host-spawn op`, desktop app approval), only for the items that changed.

- The values go through pipes only (`op item edit` reads the item JSON from its standard input), never through command arguments (`/proc/<pid>/cmdline` is world-readable) nor files.
- The rest of the item is kept, the restic `password` in particular: OpenTofu never manages it, a new password would make the repository unreadable.
- If the update fails (approval denied, `host-spawn` not forwarding the standard input...), the recipe offers to print the values, to update the item by hand.
- A change of the capabilities of a key replaces it: the old one is deleted at the end of the `apply`, the backups fail until the item is updated and External Secrets refreshes the Secrets (every 12 hours, or [force it](../docs/backups/runbook.md#refreshing-the-secrets)).

## Restoring a previous state

The replaced versions stay 90 days. Not tested:

```sh
b2 ls --long --versions b2://infrastructure-tofu-state-gz8j9y/backblaze/   # pick the file ID of the version
b2 file server-side-copy b2id://<file ID> b2://infrastructure-tofu-state-gz8j9y/backblaze/terraform.tfstate
```

The copy becomes the current version, still encrypted with the same passphrase. Then `just tofu plan <stack>`.

## Bucket rebuilt by hand

After a [rebuild of a bucket at a past date](../docs/backups/runbook.md#recovery-after-a-deletion-of-the-backups), done with the master key outside OpenTofu, bring the new bucket under OpenTofu. Not tested:

1. Remove the old bucket and key from the state, without deleting them: `just tofu run backblaze state rm "'b2_bucket.restic[\"<name>\"]'" "'b2_application_key.restic[\"<name>\"]'"` (the extra single quotes survive the interpolation of the arguments in the recipe, which the shell would otherwise strip of the double quotes).
2. Rename the entry of `restic_repositories` after the new bucket (`<new name>-gz8j9y`), import the bucket with an `import` block (its bucket ID; import support by the provider to check).
3. `just tofu apply backblaze`: a new key, pushed to the item. Then delete the temporary keys and the old bucket by hand.

## Cloudflare

Cloudflare only serves the zones `shelltopia.net` and `shelltopia.org` (the domains are registered elsewhere): no proxied record, no other Cloudflare product. The stack manages:

- **Records** (`records.tf`, one map per zone in `shelltopia-net.tf` and `shelltopia-org.tf`): mail (Purelymail, the same records in both zones, `purelymail.tf`), CAA, CNAMEs of the applications hosted by PikaPods. Comment `managed by opentofu`. The other records of the zones are left alone: those of external-dns and cloudflare-ddns ([ingress.md](../docs/ingress.md#dns)), never added to the stack; the A and AAAA records of `shelltopia.net` (hosts, firewall, WireGuard endpoints), updated by ddns-updater or by hand.
- **CAA**: `letsencrypt.org` on both zones, plus `sectigo.com` on `shelltopia.org`, required by PikaPods (its documentation and its web interface ask for it, although the certificates served are from Let's Encrypt).
- **SSL mode** `off` and **Universal SSL disabled**: nothing is proxied. While Universal SSL is enabled, Cloudflare adds hidden CAA records for its own certificate authorities to the zones that have CAA records.
- **DNSSEC**, signed by Cloudflare, `prevent_destroy`: disabling it while the DS record is still at the registrar breaks the resolution of the whole zone. The `ds` output must match the DS record at the registrar.
- **Not the zones themselves**: data sources only, the token cannot create nor delete a zone.

### Token

`infrastructure/cloudflare-tofu` ("API credential" item, field `credential`). Custom token restricted to the 2 zones, with:

- *Zone → Zone → Read*: the data sources;
- *Zone → DNS → Edit*: records and DNSSEC;
- *Zone → Zone Settings → Edit*: SSL mode;
- *Zone → SSL and Certificates → Edit*: Universal SSL.

**The Cloudflare tokens are created by hand, not by OpenTofu**, unlike the B2 keys. Creating tokens needs the *API Tokens Edit* permission, which (as far as known) allows creating a token with any permission of the account: the token of the stack would go from "DNS of 2 zones" to "administrator of the account". For the B2 keys, `writeKeys` adds little to the admin key, which can already make the backups disappear with `writeBuckets` (shorter lifecycle rules). The cluster tokens (`cloudflare-cert-manager`, `cloudflare-external-dns`, `cloudflare-ddns`) are created once and seldom rotated. They can be restricted to the client IP of the WAN (*Client IP Address Filtering*) when they are rotated.

**Every token with *DNS → Edit* can also disable DNSSEC** (same permission as the records): a stolen cluster token can break the resolution of its zones, not only change records. `just tofu plan cloudflare` shows it (`status` back to `active`).

### Cloudflare setup

- [x] Add the zones `shelltopia.net` and `shelltopia.org` to Cloudflare by hand and set the Cloudflare name servers at the registrar of each domain. Delete the records found by the initial DNS scan of Cloudflare, if any: the `apply` fails on a record of the stack that already exists.
- [x] Create the token ([above](#token)) and the `infrastructure/cloudflare-tofu` item.
- [x] `just tofu init cloudflare` and commit `.terraform.lock.hcl`.
- [x] `just tofu apply cloudflare`: records, SSL settings, DNSSEC.
- [x] Add the DS record of `just tofu run cloudflare output ds` at the registrar of each domain (or check that it matches).
- [x] `just tofu plan cloudflare` shows no change.
- [x] `dig +short CAA shelltopia.net @aria.ns.cloudflare.com` (same for `shelltopia.org`) only returns the CAA records of the stack.
- [x] [DNSViz](https://dnsviz.net) shows no error for both zones, once the DS record is published.
