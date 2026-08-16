# plunk-api — min_instance_count = 1 so there is always a warm instance (no
# cold starts). Public internet ingress: Cloudflare proxies api_domain
# straight to this service (see dns.tf's domain mapping) rather than routing
# through a GCP load balancer, so this can't be restricted to
# INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER — there is no GCP-internal path from
# Cloudflare's edge to Cloud Run.
resource "google_cloud_run_v2_service" "api" {
  name     = "plunk-api"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  labels = merge(local.common_labels, {
    component = "api"
  })

  template {
    scaling {
      min_instance_count = 1
      max_instance_count = var.api_max_instance_count
    }

    # Dedicated runtime identity (iam.tf) — grants exactly the Secret Manager
    # access this service needs instead of the shared per-project default
    # compute service account.
    service_account = google_service_account.api.email

    containers {
      image = var.api_image

      resources {
        limits = {
          cpu    = var.api_cpu
          memory = var.api_memory
        }
      }

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = var.api_env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.api_secret_env_vars
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }
    }
  }

  # cloudbuild.yaml's `deploy-api` step keeps rolling new images independently
  # of Terraform; without this, `terraform apply` would revert every CI
  # deploy back to `var.api_image`. Terraform owns scaling/ingress/labels/IAM
  # here — CI owns the image.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }

  # secret_key_ref values above are plain strings from var.api_secret_env_vars
  # — Terraform sees no attribute reference to
  # google_secret_manager_secret_iam_member.api, so there is no implicit
  # dependency edge between them. Depending on the time_sleep (iam.tf)
  # rather than the IAM grant directly also builds in a propagation buffer —
  # see that resource's comment for why the grant alone isn't enough.
  depends_on = [time_sleep.api_secret_iam_propagation]
}

# Equivalent of today's `--allow-unauthenticated`: with ingress open to the
# public internet (Cloudflare has no GCP identity to authenticate as),
# unauthenticated invocation must be allowed at the IAM layer instead —
# Plunk does its own app-level auth on top.
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  project  = var.project_id
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
