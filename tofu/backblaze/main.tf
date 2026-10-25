locals {
  # B2 bucket names are global to all accounts: the same random suffix on every bucket keeps them
  # unique and recognizable (also used by the bucket of the states, ../backend.hcl).
  bucket_suffix = "gz8j9y"
  s3_endpoint   = "https://s3.eu-central-003.backblazeb2.com"

  restic_repositories = {
    "kube-cluster01-volsync" = {
      vault = "kubernetes"
      item  = "restic-volsync"
    }
  }
}

resource "b2_bucket" "restic" {
  for_each = local.restic_repositories

  bucket_name = "${each.key}-${local.bucket_suffix}"
  bucket_type = "allPrivate"

  # The keys of the repositories cannot delete file versions, only hide them: the hidden versions
  # (forget, prune, or a deletion by a stolen key) are deleted 30 days later.
  lifecycle_rules {
    file_name_prefix             = ""
    days_from_hiding_to_deleting = 30
  }

  # Renaming a bucket replaces it. B2 refuses to delete a non-empty bucket and the admin key has
  # no deleteBuckets, this stops the plan first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "b2_application_key" "restic" {
  for_each = local.restic_repositories

  key_name   = each.key
  bucket_ids = [b2_bucket.restic[each.key].bucket_id]
  # No deleteFiles: deletions only hide files (docs/backups.md#protection-against-ransomware-and-stolen-keys).
  # No writeBuckets: the lifecycle rule cannot be changed with the key.
  capabilities = ["listBuckets", "listFiles", "readFiles", "writeFiles"]

  # Any change replaces the key, the old one is deleted at the end of the apply: the backups fail
  # until `just tofu apply` pushes the new one to 1Password and External Secrets refreshes the
  # Secrets. If the creation fails, the old key is kept.
  lifecycle {
    create_before_destroy = true
  }
}
