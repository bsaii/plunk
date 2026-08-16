# Google Cloud APIs and the Artifact Registry repository, both currently
# manual prerequisites (see the old header comment in ../../cloudbuild.yaml
# and docs/deploy-cloud-build.md). Managed here so a brand-new GCP project
# needs nothing clicked in the console before the first `terraform apply` —
# cloudbuild.yaml keeps building/pushing/deploying (see that file's header),
# Terraform owns provisioning what it deploys into.
#
# disable_on_destroy = false on every API: `terraform destroy` must never
# disable a project-wide API another workload could depend on — these APIs
# are additive, safe to leave enabled.
locals {
  required_apis = [
    "run.googleapis.com",                  # Cloud Run services, jobs, worker pools
    "artifactregistry.googleapis.com",     # Artifact Registry (image storage)
    "secretmanager.googleapis.com",        # Secret Manager (api/web/migrate/worker secrets)
    "iam.googleapis.com",                  # Service account + IAM management (iam.tf)
    "cloudbuild.googleapis.com",           # Cloud Build (../../cloudbuild.yaml)
    "cloudresourcemanager.googleapis.com", # Project-level IAM bindings (iam.tf)
  ]
}

resource "google_project_service" "required" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# The "plunk" Docker repo cloudbuild.yaml's _AR_REPO substitution and every
# image tag in it (${_REGION}-docker.pkg.dev/$PROJECT_ID/${_AR_REPO}/...)
# already assume exists. Previously a manual `gcloud artifacts repositories
# create` step (see cloudbuild.yaml's PREREQUISITES comment) — Terraform owns
# it now so a fresh project has somewhere to push on the very first build.
resource "google_artifact_registry_repository" "plunk" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repository_id
  format        = "DOCKER"
  description   = "Plunk service images (api, web, worker) built by cloudbuild.yaml"

  labels = local.common_labels

  depends_on = [google_project_service.required]
}
