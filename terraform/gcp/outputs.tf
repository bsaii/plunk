output "api_url" {
  description = "Direct *.run.app URL for plunk-api."
  value       = google_cloud_run_v2_service.api.uri
}

output "web_url" {
  description = "Direct *.run.app URL for plunk-web."
  value       = google_cloud_run_v2_service.web.uri
}

output "worker_service_url" {
  description = "Internal Cloud Run URL for plunk-worker. Set this as CLOUD_TASKS_WORKER_URL and CLOUD_TASKS_AUDIENCE after the provisioning apply."
  value       = google_cloud_run_v2_service.worker_service.uri
}

output "cloud_tasks_invoker_service_account_email" {
  description = "Dedicated identity Cloud Tasks uses to obtain an OIDC token for plunk-worker."
  value       = google_service_account.cloud_tasks_invoker.email
}

output "migrate_job_name" {
  description = "Name of the plunk-migrate Cloud Run Job."
  value       = google_cloud_run_v2_job.migrate.name
}

output "worker_pool_name" {
  description = "Name of the legacy BullMQ Worker Pool, or null after the Cloud Tasks cutover."
  value       = try(google_cloud_run_v2_worker_pool.worker[0].name, null)
}

output "maintenance_job_name" {
  description = "Name of the plunk-maintenance Cloud Run Job."
  value       = google_cloud_run_v2_job.maintenance.name
}

output "maintenance_scheduler_job_names" {
  description = "Names of the 5 Cloud Scheduler jobs that trigger plunk-maintenance."
  value       = { for k, v in google_cloud_scheduler_job.maintenance : k => v.name }
}

output "artifact_registry_repository" {
  description = "Fully-qualified Artifact Registry repo path."
  value       = "${google_artifact_registry_repository.plunk.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.plunk.repository_id}"
}

output "cloud_build_service_account_email" {
  description = "Email of the user-managed Cloud Build service account."
  value       = local.cloud_build_service_account_email
}

output "api_service_account_email" {
  description = "Runtime identity plunk-api's Cloud Run revisions execute as."
  value       = google_service_account.api.email
}

output "web_service_account_email" {
  description = "Runtime identity plunk-web's Cloud Run revisions execute as."
  value       = google_service_account.web.email
}

output "migrate_service_account_email" {
  description = "Runtime identity plunk-migrate's Cloud Run Job executions execute as."
  value       = google_service_account.migrate.email
}

output "worker_service_account_email" {
  description = "Runtime identity plunk-worker's Cloud Run service revisions execute as."
  value       = google_service_account.worker_service.email
}

output "maintenance_service_account_email" {
  description = "Runtime identity plunk-maintenance's Cloud Run Job executions execute as."
  value       = google_service_account.maintenance.email
}

output "scheduler_service_account_email" {
  description = "Identity Cloud Scheduler uses to invoke plunk-maintenance."
  value       = google_service_account.scheduler.email
}

output "api_domain_mapping_records" {
  description = "DNS records Cloud Run expects for api_domain."
  value       = google_cloud_run_domain_mapping.api.status
}

output "web_domain_mapping_records" {
  description = "DNS records Cloud Run expects for web_domain."
  value       = google_cloud_run_domain_mapping.web.status
}
