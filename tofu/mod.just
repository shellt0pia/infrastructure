set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Run any tofu command on a stack, e.g. `just tofu run cloudflare state list`')]
run stack *args:
    op run --env-file='{{ source_directory() }}/op.env' -- tofu -chdir='{{ source_directory() }}/{{ stack }}' {{ args }}

[doc('Initialize a stack (providers, lock file)')]
init stack *args: (run stack "init" args)

[doc('Show the changes of a stack')]
plan stack *args: (run stack "plan" args)

[doc('Apply the changes of a stack, commit the updated terraform.tfstate afterwards')]
apply stack *args: (run stack "apply" args)
