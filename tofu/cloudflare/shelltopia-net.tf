locals {
  # Records of shelltopia.net managed by OpenTofu (format in records.tf).
  shelltopia_net_records = merge(local.purelymail_records, {
    "caa-letsencrypt" = { name = "@", type = "CAA", ttl = 3600, data = { flags = 0, tag = "issue", value = "letsencrypt.org" } }
  })
}
