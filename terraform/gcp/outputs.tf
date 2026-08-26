output "api_url" {
  description = "Direct *.run.app URL for plunk-api. Publicly reachable (ingress is INGRESS_TRAFFIC_ALL) alongside api_domain — useful for debugging without going through Cloudflare."
  value       = google_cloud_run_v2_service.api.uri
}

output "web_url" {
  description = "Direct *.run.app URL for plunk-web. Publicly reachable (ingress is INGRESS_TRAFFIC_ALL) alongside web_domain — useful for debugging without going through Cloudflare."
  value       = google_cloud_run_v2_service.web.uri
}

output "migrate_job_name" {
  description = "Name of the plunk-migrate Cloud Run Job. Execute manually: gcloud run jobs execute <name> --region=<region> --wait"
  value       = google_cloud_run_v2_job.migrate.name
}

output "worker_pool_name" {
  description = "Name of the plunk-worker Cloud Run Worker Pool. cloudbuild.yaml's update-worker-pool step keeps its image current; Terraform owns everything else."
  value       = google_cloud_run_v2_worker_pool.worker.name
}

output "maintenance_job_name" {
  description = "Name of the plunk-maintenance Cloud Run Job. Force-run a single task for smoke testing: gcloud scheduler jobs run <scheduler_job_name> --location=<region> — see maintenance_scheduler_job_names."
  value       = google_cloud_run_v2_job.maintenance.name
}

output "maintenance_scheduler_job_names" {
  description = "Names of the 5 Cloud Scheduler jobs that trigger plunk-maintenance, keyed by task name. Force-run one: gcloud scheduler jobs run <name> --location=<region>."
  value       = {for k, v in google_cloud_scheduler_job.maintenance : k => v.name}
}

output "artifact_registry_repository" {
  description = "Fully-qualified Artifact Registry repo path (region-docker.pkg.dev/project/repo) — matches cloudbuild.yaml's image tags ($${_REGION}-docker.pkg.dev/$PROJECT_ID/$${_AR_REPO})."
  value       = "${google_artifact_registry_repository.plunk.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.plunk.repository_id}"
}

output "cloud_build_service_account_email" {
  description = "Email of the user-managed Cloud Build service account this Terraform grants IAM roles to (iam.tf). Pass to `gcloud builds submit --service-account=...` / the Cloud Build Trigger's service account field — see docs/deploy-cloud-build.md."
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
  description = "Runtime identity plunk-worker's Cloud Run Worker Pool instances execute as."
  value       = google_service_account.worker.email
}

output "maintenance_service_account_email" {
  description = "Runtime identity plunk-maintenance's Cloud Run Job executions execute as."
  value       = google_service_account.maintenance.email
}

output "scheduler_service_account_email" {
  description = "Identity Cloud Scheduler uses to invoke plunk-maintenance (granted roles/run.invoker on that job only, see maintenance.tf)."
  value       = google_service_account.scheduler.email
}

output "api_domain_mapping_records" {
  description = "DNS records Cloud Run expects for api_domain (dns.tf) — add these at Cloudflare (proxied/orange-cloud) rather than at a registrar. Typically one CNAME to ghs.googlehosted.com for a subdomain, or multiple A/AAAA records for an apex domain. Empty/incomplete until Google has verified domain ownership and provisioned the mapping — re-run `terraform refresh` or check `gcloud run domain-mappings describe` if this comes back empty right after apply."
  value       = google_cloud_run_domain_mapping.api.status
}

output "web_domain_mapping_records" {
  description = "Same as api_domain_mapping_records, for web_domain."
  value       = google_cloud_run_domain_mapping.web.status
}
