# Legacy plunk-worker BullMQ Worker Pool. Phase 3 provisions the scale-to-zero
# Cloud Tasks service in worker-service.tf first; this pool remains while the
# API's REALTIME_QUEUE_BACKEND is bullmq and is removed only by the explicit
# remove_legacy_worker_pool cutover switch.
moved {
  from = google_cloud_run_v2_worker_pool.worker
  to   = google_cloud_run_v2_worker_pool.worker[0]
}

resource "google_cloud_run_v2_worker_pool" "worker" {
  count    = var.remove_legacy_worker_pool ? 0 : 1
  name     = "plunk-worker"
  project  = var.project_id
  location = var.region

  deletion_protection = false

  labels = merge(local.common_labels, {
    component = "worker-legacy"
  })

  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = var.worker_instance_count
  }

  template {
    service_account = google_service_account.worker.email

    containers {
      image = var.worker_image

      resources {
        limits = {
          cpu    = var.worker_cpu
          memory = var.worker_memory
        }
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

  depends_on = [time_sleep.worker_secret_iam_propagation]
}
