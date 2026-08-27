# The API and the worker service have distinct runtime identities. The former
# enqueues new work; the latter needs enqueuer permission only to create a
# successor for delays longer than Cloud Tasks' 30-day schedule limit.
resource "google_service_account" "worker_service" {
  project      = var.project_id
  account_id   = "plunk-worker-service-run"
  display_name = "Plunk Cloud Tasks worker (Cloud Run service runtime identity)"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "cloud_tasks_invoker" {
  project      = var.project_id
  account_id   = "plunk-cloud-tasks-invoker"
  display_name = "Plunk Cloud Tasks OIDC invoker"

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "worker_service" {
  for_each = toset(values(var.worker_secret_env_vars))

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker_service.email}"
}

resource "time_sleep" "worker_service_secret_iam_propagation" {
  depends_on      = [google_secret_manager_secret_iam_member.worker_service]
  create_duration = "30s"
}

resource "google_cloud_run_v2_service_iam_member" "worker_cloud_tasks_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.worker_service.location
  name     = google_cloud_run_v2_service.worker_service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.cloud_tasks_invoker.email}"
}

# Cloud Tasks' service agent needs to mint the OIDC token for the dedicated
# invoker identity. This explicit binding also supports older projects where
# Google did not grant the service agent this permission automatically.
data "google_project" "current" {
  project_id = var.project_id
}

resource "google_service_account_iam_member" "cloud_tasks_service_agent_token_creator" {
  service_account_id = google_service_account.cloud_tasks_invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-cloudtasks.iam.gserviceaccount.com"
}

resource "google_service_account_iam_member" "cloud_build_acts_as_worker_service" {
  service_account_id = google_service_account.worker_service.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.cloud_build_service_account_email}"
}
