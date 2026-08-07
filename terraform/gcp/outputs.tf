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

output "load_balancer_ip" {
  description = "Reserved global static IP. Add this as an A record for both api_domain and web_domain at your DNS registrar."
  value       = google_compute_global_address.plunk_lb_ip.address
}

output "ssl_certificate_status" {
  description = "Provisioning status of the managed SSL certificate. Stays PROVISIONING until DNS for both domains resolves to load_balancer_ip."
  value       = google_compute_managed_ssl_certificate.plunk_cert.managed[0].status
}
