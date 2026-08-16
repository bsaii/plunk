# Runtime service accounts + Secret Manager IAM (P0: Cloud Run requires an
# explicit roles/secretmanager.secretAccessor grant on its own service
# identity before a secret_key_ref env var will resolve at container start —
# see https://cloud.google.com/run/docs/configuring/secrets#access-secret).
# Every Cloud Run resource here runs as its own dedicated service account
# instead of the flat per-project default compute service account, so a
# compromised plunk-web instance, say, can't read plunk-api's secrets.
#
# The Cloud Build service account is deliberately NOT created here (see
# variables.tf's cloud_build_service_account_id) — it already exists for
# this project (see docs/deploy-cloud-build.md), and Google recommends a
# user-managed build service account over the legacy
# PROJECT_NUMBER@cloudbuild.gserviceaccount.com default. This file only
# grants it the IAM roles it needs to build/push/deploy; ownership of the
# account itself stays out of band, same as the AWS side's SES IAM user
# (see terraform/aws/README.md).

locals {
  cloud_build_service_account_email = "${var.cloud_build_service_account_id}@${var.project_id}.iam.gserviceaccount.com"
}

# --- Runtime identities: one per Cloud Run resource -------------------------

resource "google_service_account" "api" {
  project      = var.project_id
  account_id   = "plunk-api-run"
  display_name = "Plunk API (Cloud Run runtime identity)"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "web" {
  project      = var.project_id
  account_id   = "plunk-web-run"
  display_name = "Plunk web dashboard (Cloud Run runtime identity)"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "migrate" {
  project      = var.project_id
  account_id   = "plunk-migrate-run"
  display_name = "Plunk migrate job (Cloud Run runtime identity)"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "worker" {
  project      = var.project_id
  account_id   = "plunk-worker-run"
  display_name = "Plunk BullMQ worker (Cloud Run Worker Pool runtime identity)"

  depends_on = [google_project_service.required]
}

# --- Secret Manager access: one binding per secret each identity reads -----
# for_each over the *values* (Secret Manager secret IDs) of each
# *_secret_env_vars map, deduplicated with toset() in case two env vars ever
# point at the same secret. The secrets themselves must already exist (see
# each map's description in variables.tf) — this only grants access, it
# never creates or reads secret values, so nothing sensitive enters state.

resource "google_secret_manager_secret_iam_member" "api" {
  for_each = toset(values(var.api_secret_env_vars))

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "web" {
  for_each = toset(values(var.web_secret_env_vars))

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.web.email}"
}

resource "google_secret_manager_secret_iam_member" "migrate" {
  for_each = toset(values(var.migrate_secret_env_vars))

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.migrate.email}"
}

resource "google_secret_manager_secret_iam_member" "worker" {
  for_each = toset(values(var.worker_secret_env_vars))

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

# --- IAM propagation buffer --------------------------------------------
# Cloud Run resolves every secret_key_ref env var against the runtime
# service account's roles/secretmanager.secretAccessor grant *at creation
# time*. IAM grants are eventually consistent, and on a fresh apply Cloud
# Run's create call can run before Google's backend has finished
# propagating a grant issued moments earlier in the same apply — the
# depends_on in api.tf/migrate.tf/worker.tf only orders the API calls, it
# doesn't wait for propagation. When that race loses, the create fails with
# a generic "Error code 7, message: The service has encountered an internal
# error. Please try again later" (gRPC code 7 is PERMISSION_DENIED — Cloud
# Run just doesn't say so plainly). A plain retry of `apply` fixes it once
# propagation catches up; these sleeps give the grants a head start so a
# fresh apply doesn't need one. No sleep for plunk-web: web_secret_env_vars
# is always empty (see variables.tf), so it has no secret_key_ref to race.
resource "time_sleep" "api_secret_iam_propagation" {
  depends_on      = [google_secret_manager_secret_iam_member.api]
  create_duration = "30s"
}

resource "time_sleep" "migrate_secret_iam_propagation" {
  depends_on      = [google_secret_manager_secret_iam_member.migrate]
  create_duration = "30s"
}

resource "time_sleep" "worker_secret_iam_propagation" {
  depends_on      = [google_secret_manager_secret_iam_member.worker]
  create_duration = "30s"
}

# --- Cloud Build: grant the existing build SA what it needs ----------------
# Mirrors the three project-level grants cloudbuild.yaml's header comment
# used to ask you to run by hand against the legacy default SA, plus two
# more a user-managed build SA needs that the legacy default gets for free:
# roles/logging.logWriter (CLOUD_LOGGING_ONLY still needs somewhere to write
# logs to) and per-runtime-SA roles/iam.serviceAccountUser (deploying a
# revision that runs as a non-default service account requires the deployer
# to be able to "act as" that service account).

resource "google_project_iam_member" "cloud_build_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${local.cloud_build_service_account_email}"
}

resource "google_project_iam_member" "cloud_build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.cloud_build_service_account_email}"
}

resource "google_artifact_registry_repository_iam_member" "cloud_build_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.plunk.location
  repository = google_artifact_registry_repository.plunk.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.cloud_build_service_account_email}"
}

resource "google_service_account_iam_member" "cloud_build_acts_as_api" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.cloud_build_service_account_email}"
}

resource "google_service_account_iam_member" "cloud_build_acts_as_web" {
  service_account_id = google_service_account.web.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.cloud_build_service_account_email}"
}

resource "google_service_account_iam_member" "cloud_build_acts_as_migrate" {
  service_account_id = google_service_account.migrate.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.cloud_build_service_account_email}"
}

resource "google_service_account_iam_member" "cloud_build_acts_as_worker" {
  service_account_id = google_service_account.worker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.cloud_build_service_account_email}"
}
