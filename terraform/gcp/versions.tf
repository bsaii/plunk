terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # >= 6.29 is required for the google_cloud_run_v2_worker_pool resource
      # (worker.tf) — Cloud Run Worker Pools only got Terraform support at
      # that version.
      version = ">= 6.29.0, < 7.0.0"
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
