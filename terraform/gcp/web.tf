# plunk-web — no min instances: the dashboard is stateless and fine scaling
# to zero (a cold start costs a few seconds on the first request after idle).
# Reachable only through the load balancer, same as plunk-api.
resource "google_cloud_run_v2_service" "web" {
  name     = "plunk-web"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  labels = merge(local.common_labels, {
    component = "web"
  })

  template {
    scaling {
      min_instance_count = 0
      max_instance_count = var.web_max_instance_count
    }

    # Dedicated runtime identity (iam.tf) — grants exactly the Secret Manager
    # access this service needs instead of the shared per-project default
    # compute service account.
    service_account = google_service_account.web.email

    containers {
      image = var.web_image

      resources {
        limits = {
          cpu    = var.web_cpu
          memory = var.web_memory
        }
      }

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = var.web_env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.web_secret_env_vars
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

  # See api.tf for why image changes are ignored here.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }
}

resource "google_cloud_run_v2_service_iam_member" "web_public" {
  project  = var.project_id
  location = google_cloud_run_v2_service.web.location
  name     = google_cloud_run_v2_service.web.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
