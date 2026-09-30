SHELL := /bin/bash

env ?= production
ifneq ("$(hosts)", "")
	flags := $(flags) "$(hosts)"
endif
ifneq ("$(module)", "")
	flags := $(flags) --module-name="$(module)"
endif
ifneq ("$(args)", "")
	flags := $(flags) --args="$(args)"
endif
ifneq ("$(limit)", "")
	flags := $(flags) --limit="$(limit)"
endif
ifneq ("$(tags)", "")
	flags := $(flags) --tags="$(tags)"
endif
ifneq ("$(app)", "")
	env_vars := $(env_vars) ANSIBLE_DISPLAY_SKIPPED_HOSTS=False
	flags := $(flags) --extra-vars="containers_list=$(app)"
endif

.PHONY: lint vault ad-hoc console dry-run provision update db-upgrade ignition help

lint: ##  ## Run ansible-lint. ## Example: make lint
	@ansible-lint

vault: ## [env=<inventory>] ## Edit vault inventory. ## Example: make vault
	@ansible-vault edit "inventories/$(env).yml" --vault-password-file="vault-pass.sh"

ad-hoc: ## [env=<inventory>] [hosts=<hosts to target>] [module=<module to use>] [args=<module arguments>] ## Run ansible ad-hoc commands. ## Example: make ad-hoc env=production hosts=cloud,home module=shell args="echo Hello world"
	@ansible --inventory="inventories/$(env).yml" $(flags) --vault-password-file="vault-pass.sh"

console: ## [env=<inventory>] [hosts=<hosts to target>] ## Open an ansible console. ## Example: make console env=production hosts=all
	@ansible-console --inventory="inventories/$(env).yml" $(flags) --vault-password-file="vault-pass.sh"

dry-run: ## [env=<inventory>] [limit=<subset of hosts to target>] [tags=<tags to execute>] [app=<containers roles to execute>] ## Dry-run the playbook. ## Example: make dry-run env=production limit=cloud,home tags=containers-enable,containers-start app=traefik,node_exporter
	@$(env_vars) ansible-playbook --inventory="inventories/$(env).yml" $(flags) provision.yml --diff --check --vault-password-file="vault-pass.sh"

provision: ## [env=<inventory>] [limit=<subset of hosts to target>] [tags=<tags to execute>] [app=<containers roles to execute>] ## Provision the hosts. ## Example: make provision env=production limit=home tags=containers-disable,containers-stop app=promtail,systemd_exporter
	@$(env_vars) ansible-playbook --inventory="inventories/$(env).yml" $(flags) provision.yml --vault-password-file="vault-pass.sh"

update: ## [env=<inventory>] [limit=<subset of hosts to target>] ## Update the hosts. ## Example: make update env=production limit=cloud,home
	@ANSIBLE_DISPLAY_SKIPPED_HOSTS=False ansible-playbook --inventory="inventories/$(env).yml" $(flags) --tags="containers-update" provision.yml --vault-password-file="vault-pass.sh"

db-upgrade: ## [env=<inventory>] [limit=<subset of hosts to target>] [app=<containers roles to execute>] ## Upgrade databases to new major version. ## Example: make db-upgrade env=production limit=cloud app=nextcloud
	@ANSIBLE_DISPLAY_SKIPPED_HOSTS=False ansible-playbook --inventory="inventories/$(env).yml" $(flags) --tags="containers-db-upgrade" provision.yml --vault-password-file="vault-pass.sh"

ignition: ## [env=<inventory>] ## Generate ignition provisionining files. ## Example: make ignition env=production
	@ansible-playbook --inventory="inventories/$(env).yml" $(flags) ignition.yml --vault-password-file="vault-pass.sh"

help: ##  ## Display this help. ## Example: make help
	@echo Usage: make [target] [options]
	@echo
	@echo The default inventory is 'production'.
	@echo
	@echo Targets:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = " ## "}; {gsub(/:/,"",$$1)}; {printf "\033[36m   %s\033[0m \033[35m%s\033[0m\n      %s\n      \033[92m%s\033[0m\n\n", $$1, $$2, $$3, $$4}'

.DEFAULT_GOAL := help
