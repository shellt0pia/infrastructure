output "ds" {
  description = "DS record of each zone, must match the one published at the registrar of the domain."
  value       = { for zone, dnssec in cloudflare_zone_dnssec.zone : zone => dnssec.ds }
}
