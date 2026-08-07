terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Bucket/prefix are supplied per environment, not hardcoded:
  #   terraform init \
  #     -backend-config="bucket=<your-terraform-state-bucket>" \
  #     -backend-config="prefix=plunk/gcp/<environment>"
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
