# 1Password access from the toolbox

How the recipes of this repository read secrets from 1Password on the workstation, the options that were evaluated and why a read-only service account was chosen.

## Context

- Workstation: Fedora Silverblue, 1Password desktop app and `1password-cli` installed on the host from the official RPM repository, *Integrate with 1Password CLI* enabled.
- Everything is run from a rootless podman toolbox built from a custom image: zsh and the whole shell configuration live there, the host has none of it.
- The toolbox had no 1Password CLI of its own: `/usr/local/bin/op` was a symlink to `host-spawn`, which runs the command on the host through the `org.freedesktop.Flatpak.Development.HostCommand` D-Bus API (`flatpak-session-helper`).
- The recipes call `op` many times, as separate processes: `talos render-config` (secrets bundle, Docker Hub and NUT credentials), `talos talosconfig`, `bootstrap secrets`, `tofu run` (`op run`), Ansible `vault-pass.sh`.

## Problem

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
- **One long-lived, read-only service account, rotated manually:** chosen.

## Decision

A service account **read-only on the `infrastructure` and `kubernetes` vaults, without expiration**, whose token is stored in the `personal` vault. The design choices, as named during the evaluation:

### Where the token lives between two commands — B: a non-exported shell parameter with a TTL

| Option | Approvals | Readable at rest by |
| --- | --- | --- |
| A. Nowhere, read again for every command | 1 per command | nobody |
| **B. Non-exported zsh parameter, 1 h TTL** | **1 per hour and per shell** | **nobody** (zsh memory, see below) |
| C. Kernel keyring `@u` with a timeout | 1 per hour, all terminals | every process of the user, host included |
| D. tmpfs file `0600` | 1 per hour, all terminals | every process of the user |
| E. Secret Service (gnome-keyring, or oo7 from Fedora 45) | 0 after login | every unsandboxed process of the user, through D-Bus; no expiration |

B is the closest to the native behaviour (an approval scoped to one terminal, then reuse for a while). A, and a "lazy A" variant where an `op` wrapper fetches the token only on its first call, were considered: A asks for every command, the lazy variant needs a wrapper and a lock for little gain. With B, a recipe that does not use `op` (`talos schematic-id`) still triggers the approval if the cache of the shell is empty or expired: accepted. oo7 does not change the Secret Service model for processes outside a Flatpak sandbox, which the toolbox is.

### Which processes get the token — 2a: the whole `just` process tree

The token is exported only to the command run through `opsa`: `just` and everything it starts (`bash`, `talosctl`, `yq`, `op`...), for the duration of the command. Injecting it into `op` only (2b) would need it to be readable from a cache shared between processes (C or D), i.e. readable at rest.

### How it is triggered — 3b: a `just` shell function

A zsh function `just` loads the token and runs `command just` with it, only when the current directory is under one of the configured repositories, with at least two arguments not starting with `-` (all the public recipes are in modules: `just`, `just <module>`, `just --list` and the shell completion never ask for an approval). No alias, no prefix to type. Exporting the token in the shell with direnv or the mise `[env]` section (3c) was rejected: it would reach every program started from the repository (editor, `kubectl`, `helm`...).

### Coexistence with the personal account — 4a: two distinct commands

- `op` in the toolbox is the real CLI, it only works with a service account token.
- `host-spawn op` is the explicit way to the personal account through the desktop app (it does not forward the toolbox environment, so never the token). It is used where write access or the `personal` vault is needed: `talos gen-secrets`, Ansible `vault-pass.sh`, service account creation.

A hybrid `op` wrapper (token set: local CLI, otherwise `host-spawn op`) was rejected: it hides which account a command uses.

### Rotation

Manual, every 30 days. The token age is the `updated_at` date of its item. Past the maximum age, `opsa` refuses to run and prints the link to the service accounts page and the steps: *Rotate token*, *Expire existing token: now*, paste the new token in the existing item (not *Save in 1Password*, which creates a new item), run the command again. It warns 5 days before.

## Security

Compared with the native mode (desktop app integration from a host terminal):

- **The cached token is not readable by other processes.** `kernel.yama.ptrace_scope=1` is a prerequisite of `1password-cli`: no process can attach to the zsh process, nor read its memory. Same guarantee as the native mode, where injecting a command into an approved session is blocked by the same setting.
- **While a command runs, the token is in the environment of every process of the `just` tree** (`just`, `bash`, `talosctl`, `tofu`…). `/proc/<pid>/environ` is readable by any process of the same user (Yama only restricts attaching), and the token would end up in a core dump of these processes. `op` processes are the exception: `/usr/bin/op` is setgid `onepassword-cli`, so the kernel marks them non-dumpable, and their `environ` cannot be read (checked: `Permission denied`). This covers the `op daemon` that every `op` command starts and that outlives it (`OP_CACHE=false` does not prevent it, it only disables caching vault data). The daemon likely inherits the token, but no other process of the user can read it.
- **A stolen token stays usable until the next rotation**, from anywhere. In the native mode, a thief only gets the values read during the approved session. Mitigations: read-only access to two vaults, the `personal` vault is out of reach, rotation every 30 days, revocation at any time from the web interface.
- The service account can read the `kubernetes` vault, so the token of the External Secrets service account too: it is a superset of the in-cluster access, not a new privilege.

## Consequences

- One approval per shell and per hour, whatever the recipe does with `op`.
- `talos render-config` no longer needs the single `op inject` and the `awk` split: one `op inject` per template is fine.
- `just tofu run` works: `op run` and `tofu` both run in the toolbox.
- `op` without a token fails in the toolbox: anything outside these recipes that expects the desktop app must call `host-spawn op`.
- Service accounts have rate limits (`op service-account ratelimit`), far above the needs of these recipes.
