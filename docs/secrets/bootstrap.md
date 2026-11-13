# Secrets: first setup

The service accounts and the 1Password items to create before the first `just bootstrap cluster`. Architecture: [README.md](README.md). The order of the whole bootstrap is in [first-bootstrap.md](../first-bootstrap.md): this setup can be done in parallel with the network and the Git repository, at any time before the bootstrap.

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kubecluster-01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| All | The `infrastructure` and `kubernetes` vaults exist, and `host-spawn op` works with the personal account. | [first-bootstrap.md](../first-bootstrap.md#phase-0--workstation) | Done |

## 1. Workstation service account

- [x] **Service account.** Create the read-only workstation service account and set up the toolbox and the shell. The recipes reading 1Password need it: `op` in the toolbox only works with its token, set by the `just` shell function. The personal account stays available through `host-spawn op` (one approval per call), see [the design](README.md#on-the-workstation-a-read-only-service-account).

## 2. Talos secrets

- [x] **Generation.** Create the `talos-secrets` document in the `infrastructure` vault, through `host-spawn op` (the service account is read-only: three approvals):

  ```sh
  just talos gen-secrets
  ```

  This is the cluster PKI: it is generated **once and never regenerated**. The recipe refuses to overwrite an existing document. `talosconfig` and `kubeconfig` can be regenerated at any time from this document (`just talos talosconfig`, `just bootstrap kubeconfig`), so there is nothing else to back up locally.

## 3. Docker Hub

- [x] **Token.** Create a Docker Hub *personal access token* with the *Public Repo Read-only* scope.
- [x] **Item.** Store it in the `infrastructure/docker-hub-kubecluster-01` item, fields `username` and `credential`, referenced by `talos/patches/containerd.yaml.j2`.

## 4. NUT

- [x] **User.** On the NAS, use (or create) a NUT user with the `upsmon secondary` role in `upsd.users`.
- [x] **Item.** Store it in the `infrastructure/nas-01-nut-server` item, fields `username` and `password`, referenced by `talos/patches/extensions.yaml.j2`.

## 5. Service account for External Secrets

- [x] **Service account.** Create it with **read-only access to the `kubernetes` vault only**, either in the web interface (*Developer → Service Accounts*) or with the CLI, signed in with the personal account:

  ```sh
  host-spawn op service-account create "kubernetes-external-secrets" --vault kubernetes:read_items
  ```

  The permissions of a service account cannot be changed after its creation, and the token is shown **only once**.

- [x] **Item.** Store the token in the `kubernetes` vault, item `1password-external-secrets-operator`, field `credential` (*API Credential* category), as referenced in `bootstrap/resources/secrets.yaml.j2`.
- [x] **Reference.** Check that it resolves with the workstation service account (`opsa` provides its token outside `just`):

  ```sh
  opsa op read op://kubernetes/1password-external-secrets-operator/credential >/dev/null && echo OK
  ```

  Expected: `OK`.

- [x] **Scope.** Check the scope of the token. The inner `op` uses the workstation service account, the outer one the External Secrets token:

  ```sh
  OP_SERVICE_ACCOUNT_TOKEN="$(opsa op read op://kubernetes/1password-external-secrets-operator/credential)" op vault list
  ```

  Expected: **only** the `kubernetes` vault.

- [x] **Test item.** Optional: create a test item in the `kubernetes` vault, to validate External Secrets after the bootstrap ([checks](../cluster/bootstrap.md#3-bootstrap)).
