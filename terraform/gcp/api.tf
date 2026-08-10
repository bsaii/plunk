# plunk-api — min_instance_count = 1 so there is always a warm instance (no
# cold starts, and a stable identity for the load balancer's health checks).
# Reachable only through the load balancer in lb.tf, never directly via its
# *.run.app URL (see ingress below).
resource "google_cloud_run_v2_service" "api" {
  name     = "plunk-api"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

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
}

# Equivalent of today's `--allow-unauthenticated`: the load balancer's
# serverless NEG needs to invoke the service, and Plunk does its own
# app-level auth on top. Ingress above still restricts *where* requests can
# originate from (LB-only), so this does not reopen direct *.run.app access.
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  project  = var.project_id
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
