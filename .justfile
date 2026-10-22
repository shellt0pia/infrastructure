set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Also set by mise.toml, exported here so that the recipes keep the same flags without mise.
export MINIJINJA_CONFIG_FILE := justfile_directory() / ".minijinja.toml"

[group('kubernetes')]
mod bootstrap

[group('kubernetes')]
mod talos

[group('infrastructure')]
mod tofu

# No `set default-list` here: it would only list the modules, not their recipes.
[private]
default:
    just --list --list-submodules

# Render a minijinja template with talos/vars.yaml, without resolving the `op://` references.
# Extra variables can be passed with `-D key=value`.
[private]
render file *args:
    minijinja-cli "{{ file }}" "{{ justfile_directory() }}/talos/vars.yaml" {{ args }}

# Same as `render`, then resolve the `op://` references.
# Every `op` call may ask for a 1Password authorization: resolve everything a recipe needs in
# a single call (see `talos render-config`).
[private]
template file *args:
    minijinja-cli "{{ file }}" "{{ justfile_directory() }}/talos/vars.yaml" {{ args }} | op inject
