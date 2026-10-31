# Secrets: evaluations and open points

How the recipes of this repository came to read 1Password through a service account: the problem, the constraints, and the options that were evaluated. The resulting design is in [README.md](README.md#on-the-workstation-a-read-only-service-account).

## Context

- Workstation: Fedora Silverblue, 1Password desktop app and `1password-cli` installed on the host from the official RPM repository, *Integrate with 1Password CLI* enabled.
- Everything is run from a rootless podman toolbox built from a custom image: zsh and the whole shell configuration live there, the host has none of it.
- The toolbox had no 1Password CLI of its own: `/usr/local/bin/op` was a symlink to `host-spawn`, which runs the command on the host through the `org.freedesktop.Flatpak.Development.HostCommand` D-Bus API (`flatpak-session-helper`).
- The recipes call `op` many times, as separate processes: `talos render-config` (secrets bundle, Docker Hub and NUT credentials), `talos talosconfig`, `bootstrap secrets`, `tofu run` (`op run`), Ansible `vault-pass.sh`.

## Problem: an approval prompt for every `op` call

Every `op` call showed the 1Password approval prompt. The expected behaviour is one approval, then about 10 minutes of reuse.

[1Password authorizes a terminal session](https://www.1password.dev/cli/app-integration-security): on Linux, the session ID is derived from the controlling TTY and the session start time, and the authorization covers that session and its sub-shells. Through `host-spawn`, each call breaks both inputs:

- **No TTY on the host side.** The pty is allocated in the container and its file descriptors are passed to the host, which cannot resolve it (`host-spawn tty`: `ttyname error: No such device`, `ps` shows `TT ?`).
- **A new session every time.** Each call gets a new SID, its parent is always `flatpak-session-helper`:

  ```text
  $ host-spawn sh -c 'ps -o pid,ppid,sid,tty,comm -p $$,$PPID'
    PID  PPID   SID TT COMMAND
  15625  5691 15625 ?  ps
   5691  4364  5691 ?  flatpak-session
  # second run: SID 15694, again a new one
  ```

Every call looks like a new, unrelated session: this is by design, no `host-spawn` or 1Password setting changes it. Batching works (`host-spawn sh -c 'op read A && op read B'` asks once), but only inside a single host process.

Workarounds that existed because of this:

- `talos render-config` concatenated every template with `#@@ <file> @@` delimiters, resolved them with a single `op inject` and split the result with `awk`.
- `just bootstrap cluster` still asked once for the talosconfig, once per node and once for the bootstrap secrets.
- `just tofu run` (`op run -- tofu`) was broken: through `host-spawn`, the `tofu` child process runs on the host, where it is not installed.

## Constraints

- Stay in the toolbox: no host terminal, no development tools installed on the host (`mise` would need a third-party repository on an atomic host).
- Do not weaken the container isolation.
- Secrets never written to persistent files, never passed as command arguments (`/proc/<pid>/cmdline` is world-readable), never in the shell history.

## Options evaluated

### Reducing the number of `op` calls

- **Batch everything in one `op inject`** (what `render-config` did): one prompt per recipe at best, at the cost of glue code in every recipe, and still several prompts per `bootstrap cluster`.
- **A central multi-file inject helper** in the root justfile: only one consumer (`render-config`), not worth it.
- **A generic `template` recipe called once per file**, like [onedr0p/home-ops](https://github.com/onedr0p/home-ops): one `op inject` per file, so *more* prompts through `host-spawn`.

All of them work around the symptom, none fixes it.

### Making the desktop app integration work from the toolbox

- **`op` installed in the toolbox, talking to the desktop app:** the app checks that the connecting process belongs to the host `onepassword-cli` group (GID 1001). Under rootless podman that GID is remapped to a subordinate GID, the connection fails (`connecting to desktop app: read: connection reset`). `groupmod -g 1001` in the container does not help.
- **Mapping the host GID 1001 into the container** (`/etc/subgid`): rejected, it weakens the isolation.
- **A persistent host shell** (`host-spawn` without arguments) reused for several calls: stable SID but still no resolvable TTY, caching unknown, and the recipes cannot use it.
- **`op signin` with the master password** (biometric unlock disabled, `OP_SESSION_*` token valid about 30 minutes): needs the master password, and `host-spawn` does not forward the environment.

### Running the recipes on the host

- **`mise` on the host + `host-spawn mise exec -- just`:** one session for the whole recipe, but needs a third-party repository on the host and leaves the toolbox shell.
- **A host terminal:** same problem, the shell configuration only exists in the toolbox.
- **`op run -- <command>` through `host-spawn`:** `<command>` runs on the host, not in the toolbox.

### Replacing the Talos recipes with topf

[topf](https://github.com/postfinance/topf) resolves secrets with [vals](https://github.com/helmfile/vals), which runs one `op read` **per secret** unless `OP_SERVICE_ACCOUNT_TOKEN` is set: it does not solve the prompts, a service account does. topf was not adopted for now, independently of this topic: with tuppr handling the upgrades and `talosctl apply-config --dry-run` already showing a diff, its remaining benefits do not outweigh the migration and the dependency on its Talos version support (v1.14 was supported the day it was released, v1.13 about two weeks later).

### Service account

A [1Password service account](https://developer.1password.com/docs/service-accounts/) authenticates with a token (`OP_SERVICE_ACCOUNT_TOKEN`), without the desktop app, its GID check or its session model. The real CLI can then run **inside** the toolbox. Variants considered:

- **One ephemeral service account per session:** rejected. Service accounts cannot be deleted with the CLI or the API, they do not appear in `op user list`, and revoking them in the web interface takes several clicks and typing their name: they would pile up.
- **A token with an expiration:** rejected. Rotating an expiring token in the web interface creates a second service account with the same name and no expiration. Without an expiration, the rotation happens in place and offers *Expire existing token: now*.
- **1Password Credential Broker:** relies on workload identity federation (GitHub, Google Cloud...), meant for CI/CD, not for a workstation.
- **One long-lived, read-only service account, rotated manually:** chosen, see [the design](README.md#on-the-workstation-a-read-only-service-account).

## Open points

| Topic | Notes |
| --- | --- |
| Rotation | Manual: `opsa` warns 5 days before and refuses to run past 30 days ([procedure](runbook.md#rotating-the-workstation-token)). |
| Secret Service (oo7) | Does not change the model for processes outside a Flatpak sandbox, which the toolbox is ([option E](README.md#where-the-token-lives-between-two-commands--b-a-non-exported-shell-parameter-with-a-ttl)). |
| topf | Not adopted for now ([why](#replacing-the-talos-recipes-with-topf)). |
| Copy of the critical secrets outside 1Password | The Talos secrets bundle and the restic passwords only exist in 1Password: without access to the account, the cluster cannot be rebuilt nor the backups read ([1Password unavailable](runbook.md#1password-unavailable)). Decide whether an offline copy is wanted, and where. |
