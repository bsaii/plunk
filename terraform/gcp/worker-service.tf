# plunk-worker — internal, scale-to-zero HTTP worker for Cloud Tasks.
# This is intentionally a Cloud Run Service (not a Job): every Cloud Tasks
# delivery is an authenticated HTTP request and Cloud Run can cold-start it
# on demand. The legacy Worker Pool remains in worker.tf until the guarded
# cutover removes it.
resource "google_cloud_run_v2_service" "worker_service" {
  name     = "plunk-worker"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  deletion_protection = false

  labels = merge(local.common_labels, {
    component = "worker"
  })

  template {
    scaling {
      min_instance_count = 0
      max_instance_count = var.worker_max_instance_count
    }

    service_account = google_service_account.worker_service.email

    containers {
      image = var.worker_image

      resources {
        limits = {
          cpu    = var.worker_cpu
          memory = var.worker_memory
        }
        cpu_idle = true
      }

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = var.worker_env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.worker_secret_env_vars
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

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }

  depends_on = [time_sleep.worker_service_secret_iam_propagation]
}
