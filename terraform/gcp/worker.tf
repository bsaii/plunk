# plunk-worker — the BullMQ worker (apps/api/src/jobs/worker.ts) as a Cloud
# Run Worker Pool. Worker Pools exist specifically for continuously-running
# background processes that never bind an HTTP port and so can't pass a
# regular Cloud Run service's startup health check — see
# https://docs.cloud.google.com/run/docs/configuring/workerpools/containers.
# Previously dropped from both cloudbuild.yaml and this Terraform as
# "TBD" (see git history); restored now that Worker Pools have direct
# Terraform support (google provider >= 6.29, see versions.tf).
#
# min_instance_count defaults to 1 (see variables.tf) rather than 0: unlike
# plunk-web, there is no HTTP request to trigger a cold start on — scaling to
# zero would just leave queued email/campaign/workflow jobs waiting until an
# instance comes back. Same lifecycle.ignore_changes pattern as
# api.tf/web.tf/migrate.tf: cloudbuild.yaml's `update-worker-pool` step keeps
# rolling the image forward independently of Terraform.
#
# NOTE: google_cloud_run_v2_worker_pool is a newer resource (GA in provider
# ~6.29). Run `terraform validate` / `terraform plan` against a real registry
# mirror before applying — verify this shape against the current provider
# docs first if it's been a while since this file was last touched.
resource "google_cloud_run_v2_worker_pool" "worker" {
  name     = "plunk-worker"
  project  = var.project_id
  location = var.region

  labels = merge(local.common_labels, {
    component = "worker"
  })

  template {
    # Dedicated runtime identity (iam.tf) — grants exactly the Secret
    # Manager access the worker needs instead of the shared per-project
    # default compute service account.
    service_account = google_service_account.worker.email

    scaling {
      min_instance_count = var.worker_min_instance_count
      max_instance_count = var.worker_max_instance_count
    }

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

  # cloudbuild.yaml's `update-worker-pool` step keeps rolling new images
  # independently of Terraform; without this, `terraform apply` would revert
  # every CI deploy back to `var.worker_image`. Terraform owns
  # scaling/labels/IAM here — CI owns the image. See api.tf for the same
  # reasoning.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }
}
