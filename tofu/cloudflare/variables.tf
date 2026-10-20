variable "state_passphrase" {
  description = "Passphrase used to encrypt the state and plans (at least 16 characters)."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID."
  type        = string
}
