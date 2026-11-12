# AGENTS.md

Home infrastructure mono repository. Two stacks live side by side:

- **Legacy**: Fedora CoreOS hosts provisioned with Ansible (Podman quadlets), in `ansible/`, driven by its `Makefile` (`make help` from `ansible/`).
- **Kubernetes (WIP)**: a 3-node Talos cluster managed by Flux, driven by `just` recipes (`just`, then `just <module>`).

## Read first

- [README.md](README.md): overview of both stacks, tooling (`mise.toml`) and main commands.
- [docs/README.md](docs/README.md): index of the documentation, the topics and their file format.
- [docs/conventions.md](docs/conventions.md): the rules to follow for every change (layout, Flux apps, charts, namespaces, network policies, pod security, secrets, Talos, OpenTofu, documentation). Use `kubernetes/apps/cert-manager` and `kubernetes/apps/network` as examples.
- [docs/reference.md](docs/reference.md): names, addresses, ports, namespaces, 1Password items and schedules. It only collects them: update the linked topic document too.

## Then, depending on the task

- A topic of `docs/<topic>/`: `README.md` (architecture and decisions), `bootstrap.md`, `runbook.md`, `evaluations.md`.
- [docs/roadmap.md](docs/roadmap.md): what is left to build and the open questions.
- [talos/README.md](talos/README.md), [tofu/README.md](tofu/README.md), [docs/secrets/README.md](docs/secrets/README.md).

## Commands

- **Never** run a command that changes the infrastructure, even when asked to fix something: `kubectl apply/edit/patch/delete/scale/rollout`, `flux reconcile/suspend/resume`, `talosctl apply-config/upgrade/reboot/reset`, `helm`/`helmfile` installs, `tofu apply`, `ansible-playbook`. The cluster follows Git: change the files, Flux applies them.
- A command that only reads the live infrastructure (`kubectl get/describe/logs`, `flux get`, `talosctl get/logs`, `tofu plan`, SSH to a host) runs only after asking the user and getting an explicit approval.
- Never run the `just` recipes or the `make` targets: they read 1Password or reach the infrastructure. Read them to understand what they do, and use the local tools below.
- 1Password is not available to the agent: never run `op` or `host-spawn`. Files only hold `op://` references, never a secret value.

## Checking a change

Only local render tools, without the cluster, the network or 1Password:

- `kubectl kustomize kubernetes/apps/<namespace>` and `kubectl kustomize kubernetes/apps/<namespace>/<app>/app`.
- `flux build kustomization <name> --path kubernetes/apps/<namespace>/<app>/app --kustomization-file kubernetes/apps/<namespace>/<app>/ks.yaml --dry-run`: also applies the `postBuild` substitutions and the components.
- `minijinja-cli talos/patches/<patch>.yaml.j2 talos/vars.yaml` (flags from `.minijinja.toml`), never piped to `op inject`: the `op://` references stay unresolved.
- `yamllint -c .yamllint.yml <path>`, `markdownlint-cli2 <path>` (reads `.markdownlint.yml`) and `tofu fmt -check -recursive tofu/`.

With network access, which the sandbox asks for (registries, schemas, providers):

- A chart: `yq '.spec.values' <app>/app/helmrelease.yaml > .scratch/<app>-values.yaml`, then `helm template <app> <url> --version <tag> --values .scratch/<app>-values.yaml` with the `url` and `tag` of the `OCIRepository` (`--repo <url> <chart>` for a `HelmRepository`). The output goes in `.scratch/`.
- The schemas: `kubectl kustomize <path> > .scratch/<app>.yaml`, then `kubeconform -strict -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' .scratch/<app>.yaml`.
- OpenTofu: `tofu -chdir=tofu/<stack> init -backend=false -lockfile=readonly`, then `tofu -chdir=tofu/<stack> validate`. Without the backend: no state, no 1Password.

A missing tool is installed by the user (`mise install`), not by the agent.

## Files

- `kubeconfig` and `talosconfig` at the root hold the admin credentials of the cluster: generated, ignored by Git, never read, printed or committed. Same for the generated `ansible/files/coreos/*.bu` and `*.ign`.
- Temporary files (rendered charts, test outputs) go in `.scratch/`, ignored by Git.

## Versions

Renovate updates the versions of the charts, images and tools (`.renovaterc.json5`): do not bump them by hand unless asked. Keep the `# renovate:` comment on the line before each version of `talos/` (`talos/vars.yaml`).

## Style

- Documentation and comments in English, in the style of the existing documents: short sentences, a link to the topic document rather than a long explanation ([conventions](docs/conventions.md#documentation)).
- Commit messages: one line, imperative, no prefix (`Add …`, `Move …`), as in `git log`.

## Do not

- Commit secrets: they live in 1Password (`ExternalSecret` in the cluster). `ansible/inventories/production.yml` is encrypted with `ansible-vault`, never decrypt or rewrite it.
- Hardcode addresses in manifests or Talos patches (use FQDNs), except the pinned LoadBalancer addresses allocated in `docs/reference.md`.
- Leave the documentation behind: a change to the infrastructure updates its topic document in the same commit.
