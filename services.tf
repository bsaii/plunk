# Google Cloud APIs and the Artifact Registry repository, both currently
# manual prerequisites (see the old header comment in ../../cloudbuild.yaml).
# Managed here so a brand-new GCP project needs nothing clicked in the console
# before the first terraform apply.
locals {
  required_apis = [
    "run.googleapis.com",                  # Cloud Run services and jobs
    "artifactregistry.googleapis.com",     # Artifact Registry (image storage)
    "secretmanager.googleapis.com",        # Secret Manager (runtime secrets)
    "iam.googleapis.com",                  # Service account + IAM management
    "cloudbuild.googleapis.com",           # Cloud Build (../../cloudbuild.yaml)
    "cloudresourcemanager.googleapis.com", # Project-level IAM bindings
    "cloudscheduler.googleapis.com",       # Cloud Scheduler (maintenance.tf)
    "cloudtasks.googleapis.com",           # Cloud Tasks (queues.tf)
  ]
}

resource "google_project_service" "required" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "plunk" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repository_id
  format        = "DOCKER"
  description   = "Plunk service images (api, web, worker) built by cloudbuild.yaml"

  labels = local.common_labels

  depends_on = [google_project_service.required]
}
