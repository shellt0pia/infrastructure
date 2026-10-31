# Secrets: runbook

Day-to-day administration of the access to 1Password. Architecture: [README.md](README.md).

## Which account for which command

| Command | Account | Used for |
| --- | --- | --- |
| `op` in the toolbox | Workstation service account (read-only, `infrastructure` and `kubernetes` vaults) | Every recipe: `op inject`, `op read`, `op run`. The token is loaded by the `just` function of the shell, or by `opsa <command>` outside of `just`. |
| `host-spawn op` | Personal account, through the desktop app (one approval per call) | Writes and the `personal` vault: `just talos gen-secrets`, the push of the keys by `just tofu apply`, Ansible `vault-pass.sh`, creating a service account. |

`op` without a token fails in the toolbox. Anything outside of the recipes that needs 1Password reads must go through `opsa` (service account) or `host-spawn op` (personal account).

## Rotating the workstation token

Every 30 days. The token age is the `updated_at` date of its item (`personal` vault). `opsa` warns 5 days before and refuses to run past the maximum age, printing the link to the service accounts page and these steps:

1. In the web interface of 1Password, open the service account: *Rotate token*.
2. *Expire existing token: now*.
3. Paste the new token in the **existing** item. Not *Save in 1Password*, which creates a new item.
4. Run the command again.

Rotating in place only works for a token without expiration: an expiring token would create a second service account with the same name ([why](evaluations.md#service-account)).

A stolen token stays usable until the next rotation, from anywhere, and can be revoked at any time from the web interface ([security](README.md#security)).

## Changing the permissions of a service account

The permissions of a service account cannot be changed after its creation, and its token is shown only once ([creation](bootstrap.md#5-service-account-for-external-secrets)).

## Tokens to renew

| Token | Item | Used by |
| --- | --- | --- |
| Workstation service account | `personal` vault | Every recipe, [rotation above](#rotating-the-workstation-token) |
| `kubernetes-external-secrets` service account | `kubernetes/1password-service-account-kubernetes` | External Secrets |
| Docker Hub personal access token | `infrastructure/docker-hub` | containerd of the nodes (rate limit) |
| GitHub fine-grained token (private repository only) | `infrastructure/flux-github-token` | Flux |
| Cloudflare tokens | `kubernetes/cloudflare-cert-manager`, `kubernetes/cloudflare-external-dns`, `kubernetes/cloudflare-ddns`, `infrastructure/cloudflare-tofu` | cert-manager, external-dns, cloudflare-ddns, OpenTofu |
| B2 keys | `kubernetes/restic-volsync`, `infrastructure/restic-nas`, `infrastructure/backblaze-b2-tofu-*` | VolSync, Backrest, OpenTofu (the `restic-*` keys are managed by OpenTofu, see [tofu/README.md](../../tofu/README.md)) |

The expiration dates of the tokens are not tracked in the repository: the [roadmap](../roadmap.md#to-check-or-watch) only keeps a reminder to renew them, and the workstation token has its own 30-day rotation.
