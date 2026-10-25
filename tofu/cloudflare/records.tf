locals {
  # Records of every zone, keyed by "<zone>/<key>". In the files of the zones, the names are relative
  # to the zone ("@" for the apex) and the attributes are the ones of the Cloudflare API:
  # `content`, or `data` (CAA, SRV...), `priority` (MX; taken from `data` for SRV), `ttl`
  # (1 = automatic, the default).
  # The key is the address of the record in the state: renaming it replaces the record, unless a
  # `moved` block goes with it.
  records = merge([
    for zone, records in local.zones : {
      for key, record in records : "${zone}/${key}" => merge(record, { zone = zone })
    }
  ]...)
}

resource "cloudflare_dns_record" "record" {
  for_each = local.records

  zone_id  = data.cloudflare_zone.zone[each.value.zone].id
  name     = each.value.name == "@" ? each.value.zone : "${each.value.name}.${each.value.zone}"
  type     = each.value.type
  ttl      = try(each.value.ttl, 1)
  content  = try(each.value.content, null)
  data     = try(each.value.data, null)
  priority = try(each.value.priority, each.value.data.priority, null)
  proxied  = false
  comment  = "managed by opentofu"
}
