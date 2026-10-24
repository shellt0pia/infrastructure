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

# Structured log line on stderr, e.g. `just log info "Running stage..." stage nodes`.
# The `fatal` level exits with an error.
[private]
[positional-arguments]
[no-exit-message]
log level message *fields:
    gum log --time rfc3339 --structured --level "$1" "$2" "${@:3}"

# Render a minijinja template with talos/vars.yaml, then resolve the `op://` references with the
# workstation service account (docs/1password-local-access.md): `op` can be called any number of
# times, without prompts. Extra variables can be passed with `-D key=value`.
[private]
template file *args:
    minijinja-cli "{{ file }}" "{{ justfile_directory() }}/talos/vars.yaml" {{ args }} | op inject
