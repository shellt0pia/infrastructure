# Existing resources are adopted with import blocks, then `just tofu plan cloudflare`
# must show no change. Import blocks can be removed once applied. Example:
#
# import {
#   to = cloudflare_zone.main
#   id = "<zone id>"
# }
#
# resource "cloudflare_zone" "main" {
#   account = { id = var.cloudflare_account_id }
#   name    = "domain.tld"
# }
#
# `just tofu run cloudflare plan -generate-config-out=generated.tf` writes a first
# version of the configuration of the imported resources.
