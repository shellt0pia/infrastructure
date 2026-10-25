locals {
  # Mail hosted by Purelymail, same records in every zone (format in records.tf).
  purelymail_records = {
    "mx"               = { name = "@", type = "MX", ttl = 3600, priority = 10, content = "mailserver.purelymail.com" }
    "spf"              = { name = "@", type = "TXT", ttl = 3600, content = "\"v=spf1 include:_spf.purelymail.com -all\"" }
    "dmarc"            = { name = "_dmarc", type = "CNAME", ttl = 3600, content = "dmarcroot.purelymail.com" }
    "dkim-purelymail1" = { name = "purelymail1._domainkey", type = "CNAME", ttl = 3600, content = "key1.dkimroot.purelymail.com" }
    "dkim-purelymail2" = { name = "purelymail2._domainkey", type = "CNAME", ttl = 3600, content = "key2.dkimroot.purelymail.com" }
    "dkim-purelymail3" = { name = "purelymail3._domainkey", type = "CNAME", ttl = 3600, content = "key3.dkimroot.purelymail.com" }
    "autoconfig"       = { name = "autoconfig", type = "CNAME", ttl = 3600, content = "autoconfig.purelymail.com" }
    "srv-autodiscover" = { name = "_autodiscover._tcp", type = "SRV", ttl = 3600, data = { priority = 0, weight = 0, port = 443, target = "autodiscover.purelymail.com" } }
    "srv-imaps"        = { name = "_imaps._tcp", type = "SRV", ttl = 3600, data = { priority = 0, weight = 1, port = 993, target = "imap.purelymail.com" } }
    "srv-imap"         = { name = "_imap._tcp", type = "SRV", ttl = 3600, data = { priority = 0, weight = 0, port = 0, target = "." } }
    "srv-pop3s"        = { name = "_pop3s._tcp", type = "SRV", ttl = 3600, data = { priority = 10, weight = 1, port = 995, target = "pop3.purelymail.com" } }
    "srv-pop3"         = { name = "_pop3._tcp", type = "SRV", ttl = 3600, data = { priority = 0, weight = 0, port = 0, target = "." } }
    "srv-sieve"        = { name = "_sieve._tcp", type = "SRV", ttl = 3600, data = { priority = 0, weight = 1, port = 4190, target = "mailserver.purelymail.com" } }
    "srv-submissions"  = { name = "_submissions._tcp", type = "SRV", ttl = 3600, data = { priority = 0, weight = 1, port = 465, target = "smtp.purelymail.com" } }
    "srv-submission"   = { name = "_submission._tcp", type = "SRV", ttl = 3600, data = { priority = 0, weight = 0, port = 0, target = "." } }
  }
}
