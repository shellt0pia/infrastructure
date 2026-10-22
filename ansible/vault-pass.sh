#!/usr/bin/env bash

set -e

# Personal account through the desktop app on the host: the `personal` vault is out of reach of
# the workstation service account, and `make` does not provide its token anyway.
host-spawn op read "op://personal/Ansible Vault - infrastructure/password"
