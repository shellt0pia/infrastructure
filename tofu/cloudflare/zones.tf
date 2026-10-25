locals {
  zones = {
    "shelltopia.net" = local.shelltopia_net_records
    "shelltopia.org" = local.shelltopia_org_records
  }
}

data "cloudflare_zone" "zone" {
  for_each = local.zones

  filter = { name = each.key }
}

# Encryption mode of the Cloudflare proxy, unused: no record is proxied.
resource "cloudflare_zone_setting" "ssl" {
  for_each = local.zones

  zone_id    = data.cloudflare_zone.zone[each.key].id
  setting_id = "ssl"
  value      = "off"
}

# While Universal SSL is enabled, Cloudflare adds CAA records for its own certificate authorities to
# a zone that has CAA records (hidden from the dashboard, visible with dig), which widens the list
# of the CAs allowed to issue certificates. Nothing uses these certificates, no record is proxied.
resource "cloudflare_universal_ssl_setting" "zone" {
  for_each = local.zones

  zone_id = data.cloudflare_zone.zone[each.key].id
  enabled = false
}

# Zones signed by Cloudflare, their DS records are published at the registrars (output `ds`).
# Disabling DNSSEC while the DS record is still at the registrar makes the zone fail validation.
# To disable it, remove the DS record at the registrar first, wait for its TTL to expire, then
# set `status = "disabled"`.
resource "cloudflare_zone_dnssec" "zone" {
  for_each = local.zones

  zone_id = data.cloudflare_zone.zone[each.key].id
  status  = "active"

  lifecycle {
    prevent_destroy = true
  }
}
