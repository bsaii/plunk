# plunk-worker — the BullMQ worker (apps/api/src/jobs/worker.ts) as a Cloud
# Run Worker Pool. Worker Pools exist specifically for continuously-running
# background processes that never bind an HTTP port and so can't pass a
# regular Cloud Run service's startup health check — see
# https://docs.cloud.google.com/run/docs/configuring/workerpools/containers.
# Previously dropped from both cloudbuild.yaml and this Terraform as
# "TBD" (see git history); restored now that Worker Pools have direct
# Terraform support (google provider >= 6.37, see versions.tf).
#
# worker_instance_count defaults to 1 (see variables.tf) rather than 0:
# unlike plunk-web, there is no HTTP request to trigger a cold start on —
# scaling to zero would just leave queued email/campaign/workflow jobs
# waiting until an instance comes back. Same lifecycle.ignore_changes
# pattern as api.tf/web.tf/migrate.tf: cloudbuild.yaml's
# `update-worker-pool` step keeps rolling the image forward independently
# of Terraform.
#
# `scaling` is a top-level field on this resource (a sibling of `template`,
# NOT nested inside it — unlike google_cloud_run_v2_service/_job, whose
# scaling lives under template.scaling). manual_instance_count +
# scaling_mode = "MANUAL" (the provider's own default) is used deliberately
# instead of min/max_instance_count: see
# https://docs.cloud.google.com/run/docs/deploy-worker-pools and the
# provider schema (resource_cloud_run_v2_worker_pool.go) — MANUAL is the
# well-supported mode; AUTOMATIC scaling_mode exists in the schema but is
# not something this config relies on.
resource "google_cloud_run_v2_worker_pool" "worker" {
  name     = "plunk-worker"
  project  = var.project_id
  location = var.region

  labels = merge(local.common_labels, {
    component = "worker"
  })

  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = var.worker_instance_count
  }

  template {
    # Dedicated runtime identity (iam.tf) — grants exactly the Secret
    # Manager access the worker needs instead of the shared per-project
    # default compute service account.
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

  # The secret_key_ref values above are plain strings from
  # var.worker_secret_env_vars — Terraform sees no attribute reference to
  # google_secret_manager_secret_iam_member.worker, so there is no implicit
  # dependency edge between them. Without this, Terraform is free to deploy
  # this revision before granting the runtime service account
  # roles/secretmanager.secretAccessor, and the container fails to start
  # (permission denied resolving the secret) on a first/concurrent apply.
  depends_on = [google_secret_manager_secret_iam_member.worker]
}
