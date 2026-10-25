# Pushed to 1Password by `just tofu apply` (sync-1password recipe in ../mod.just), only the items
# whose values changed. Missing items are created, with a generated `password` field when
# `generate_password` is set (restic repository password, never managed by OpenTofu).
output "onepassword_items" {
  description = "1Password items to create or update: `fields` are text fields, `secrets` concealed ones."
  sensitive   = true
  value = [
    for name, repository in local.restic_repositories : {
      vault             = repository.vault
      item              = repository.item
      generate_password = true
      fields = {
        repository      = "s3:${local.s3_endpoint}/${b2_bucket.restic[name].bucket_name}"
        "access-key-id" = b2_application_key.restic[name].application_key_id
      }
      secrets = {
        "secret-access-key" = b2_application_key.restic[name].application_key
      }
    }
  ]
}
