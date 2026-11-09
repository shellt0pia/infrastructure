locals {
  # Records of shelltopia.net managed by OpenTofu (format in records.tf).
  shelltopia_net_records = merge(local.purelymail_records, {
    "caa-letsencrypt" = { name = "@", type = "CAA", ttl = 3600, data = { flags = 0, tag = "issue", value = "letsencrypt.org" } }
    "a-wg-milkywan" = { name = "wg-milkywan", type = "A", content = "45.13.104.160" }
    "aaaa-wg-milkywan" = { name = "wg-milkywan", type = "AAAA", content = "2a0e:e701:2132::1" }
  })
}
