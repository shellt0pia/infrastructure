terraform {
  required_version = ">= 1.13.0"

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "0.14.1"
    }
  }

  # Shared settings in ../backend.hcl, passed by `just tofu init`.
  backend "s3" {
    key = "backblaze/terraform.tfstate"
  }

  # The passphrase is injected from 1Password by `op run`, see ../op.env.
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method   = method.aes_gcm.main
      enforced = true
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}
