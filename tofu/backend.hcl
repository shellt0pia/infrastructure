# S3 backend settings shared by every stack, passed by `just tofu init`. Each stack only sets its
# `key` (`<stack>/terraform.tfstate`).
#
# The bucket is created by hand, outside OpenTofu (tofu/README.md): no stack can destroy its own
# backend. Its key cannot delete file versions, and the replaced states are kept 90 days.
# Credentials: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, see op.env.

bucket = "infrastructure-tofu-state-gz8j9y"
region = "eu-central-003"
endpoints = {
  s3 = "https://s3.eu-central-003.backblazeb2.com"
}
use_path_style = true

# B2 is not AWS: no STS, no IMDS, no account ID, no SDK checksums.
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_s3_checksum            = true

# No locking: B2 does not implement the conditional writes (If-None-Match) of the native S3
# locking, `PutObject` fails with 501 NotImplemented (tested on 2026-10-25). Single operator.
use_lockfile = false
