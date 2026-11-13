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

## Replacing a token synced to the cluster

For a secret of the `kubernetes` vault pulled by an `ExternalSecret` (the Cloudflare tokens, the `restic-*` keys...): the ExternalSecrets refresh every hour or so, force them when the new value is needed now.

- [ ] **New token.** Create it at its provider (the Cloudflare dashboard, `just tofu apply backblaze` for the B2 keys of the backups), then write it in the **existing** item and field. The workstation service account is read-only: use the web interface or `host-spawn op item edit`.
- [ ] **Sync:**

  ```sh
  kubectl -n <namespace> annotate externalsecret <name> force-sync="$(date +%s)" --overwrite
  kubectl -n <namespace> get externalsecret <name>
  ```

  Expected: `SecretSynced`, with a recent refresh.

- [ ] **Restart the consumers that read it as an environment variable**, if they do not carry `reloader.stakater.com/auto` ([Reloader](../cluster/README.md#reloader)). external-dns and cloudflare-ddns carry it: check that a new pod started after the sync. Restart by hand the others, and the opted-in ones if Reloader was down during the sync:

  ```sh
  kubectl -n <namespace> get pods
  kubectl -n <namespace> rollout restart deploy/<name>
  ```

- [ ] **Revoke the old token** at its provider, once its consumers work with the new one.

The token of External Secrets itself (`1password-external-secrets-operator`) is not pulled by an ExternalSecret but injected by the bootstrap: after replacing the item, apply it again.

```sh
just bootstrap secrets
kubectl get clustersecretstore onepassword
```

Expected: the `READY` column is `True`.

## 1Password unavailable

The service is down, the account is locked, or the workstation token was revoked.

- **The cluster keeps running.** The Secrets that External Secrets already created stay in place, the ExternalSecrets only fail to refresh until the service is back (`kubectl get externalsecrets -A`). Nothing new can be synced meanwhile: a new application, a rotated token.
- **The workstation loses every recipe that reads 1Password**: all the `just talos`, `just bootstrap`, `just tofu` and `just kube volsync-*` recipes. `kubectl`, `talosctl` and `flux` keep working with the `kubeconfig` and `talosconfig` already at the root of the repository (generated, not in Git).
- **Nothing can be rebuilt nor restored.** The Talos secrets bundle (the PKI of the cluster) and the restic passwords only exist in 1Password: no [rebuild of a node or of the cluster](../backups/runbook.md#full-rebuild), no [restore](../backups/runbook.md#recipes). There is no copy elsewhere yet ([open point](evaluations.md#open-points)).

A revoked or expired workstation token only needs the [rotation](#rotating-the-workstation-token). If the revocation follows a suspicion of compromise, see the [compromised cluster](../backups/runbook.md#ransomware-or-compromised-cluster) procedure.

## Changing the permissions of a service account

The permissions of a service account cannot be changed after its creation, and its token is shown only once ([creation](bootstrap.md#5-service-account-for-external-secrets)).

## Tokens to renew

| Token | Item | Used by |
| --- | --- | --- |
| Workstation service account | `personal` vault | Every recipe, [rotation above](#rotating-the-workstation-token) |
| `kubernetes-external-secrets` service account | `kubernetes/1password-external-secrets-operator` | External Secrets |
| Docker Hub personal access token | `infrastructure/docker-hub-kubecluster-01` | containerd of the nodes (rate limit) |

| Cloudflare tokens | `kubernetes/cloudflare-cert-manager`, `kubernetes/cloudflare-external-dns`, `kubernetes/cloudflare-ddns`, `infrastructure/cloudflare-tofu` | cert-manager, external-dns, cloudflare-ddns, OpenTofu |
| B2 keys | `kubernetes/restic-volsync`, `infrastructure/restic-nas`, `infrastructure/backblaze-b2-tofu-*` | VolSync, Backrest, OpenTofu (the `restic-*` keys are managed by OpenTofu, see [tofu/README.md](../../tofu/README.md)) |

The expiration dates of the tokens are not tracked in the repository: the [roadmap](../roadmap.md#to-check-or-watch) only keeps a reminder to renew them, and the workstation token has its own 30-day rotation.
