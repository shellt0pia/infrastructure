set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

# Ansible (Fedora CoreOS hosts) is still managed through its Makefile, see `make -C ansible help`.

[group('kubernetes')]
mod talos

[private]
default:
    just --list --list-submodules

minijinja := "minijinja-cli --strict --trim-blocks --lstrip-blocks --autoescape=none"

# Render a minijinja template with talos/vars.yaml, without resolving the `op://` references.
# Extra variables can be passed with `-D key=value`.
[private]
render file *args:
    {{ minijinja }} "{{ file }}" "{{ justfile_directory() }}/talos/vars.yaml" {{ args }}

# Same as `render`, then resolve the `op://` references.
# Every `op` call may ask for a 1Password authorization: resolve everything a recipe needs in
# a single call (see `talos render-config`).
[private]
template file *args:
    {{ minijinja }} "{{ file }}" "{{ justfile_directory() }}/talos/vars.yaml" {{ args }} | op inject
