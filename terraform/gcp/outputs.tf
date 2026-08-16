output "api_url" {
  description = "Direct Cloud Run URL for plunk-api. Not reachable from the internet once ingress is LB-only — informational / for debugging via the console only."
  value       = google_cloud_run_v2_service.api.uri
}

output "web_url" {
  description = "Direct Cloud Run URL for plunk-web. Not reachable from the internet once ingress is LB-only — informational / for debugging via the console only."
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

output "load_balancer_ip" {
  description = "Reserved global static IP. Add this as an A record for both api_domain and web_domain at your DNS registrar."
  value       = google_compute_global_address.plunk_lb_ip.address
}

output "ssl_certificate_name" {
  description = "Name of the managed SSL certificate. The hashicorp/google provider does not expose provisioning status as a resource attribute (there is no `managed[0].status` on google_compute_managed_ssl_certificate) — check it with: gcloud compute ssl-certificates describe <this output> --format='value(managed.status,managed.domainStatus)'. Stays PROVISIONING until DNS for both domains resolves to load_balancer_ip."
  value       = google_compute_managed_ssl_certificate.plunk_cert.name
}
