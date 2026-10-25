locals {
  # Records of shelltopia.org managed by OpenTofu (format in records.tf).
  shelltopia_org_records = merge(local.purelymail_records, {
    "caa-letsencrypt" = { name = "@", type = "CAA", ttl = 3600, data = { flags = 0, tag = "issue", value = "letsencrypt.org" } }
    # Required by PikaPods.
    "caa-sectigo" = { name = "@", type = "CAA", ttl = 3600, data = { flags = 0, tag = "issue", value = "sectigo.com" } }
    "id"     = { name = "id", type = "CNAME", content = "silver-hamster.pikapod.net" }
    "uptime" = { name = "uptime", type = "CNAME", content = "strategic-asp.pikapod.net" }
  })
}
