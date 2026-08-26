# plunk-maintenance — the 5 scheduled maintenance sweeps (domain verification,
# segment counts, and the 3 cleanup jobs) as a Cloud Run Job driven by Cloud
# Scheduler, instead of BullMQ's in-process repeatable jobs (app.ts, guarded
# behind QUEUE_BACKEND — see app/constants.ts). Modeled directly on
# migrate.tf: same runtime (the api image, different entrypoint — see
# Dockerfile.services' maintenance-runner target), same
# lifecycle.ignore_changes/time_sleep pattern.
#
# Unlike plunk-migrate (deliberately never auto-executed), this Job IS wired
# to a trigger — but a self-imposed one (Cloud Scheduler), not incoming
# traffic, so it still fits Cloud Run Jobs' run-to-completion model rather
# than a Service's request-response model.
#
# One image serves all 5 schedules: `containers[0].args` is left unset here
# so a direct/manual `gcloud run jobs execute plunk-maintenance` fails loud
# (see maintenance-runner.ts) instead of silently running the wrong task.
# Each google_cloud_scheduler_job below supplies its own `--task=<name>` via
# a per-invocation container override on the Cloud Run Admin API's
# projects.locations.jobs.run method, not a static Terraform default.
resource "google_cloud_run_v2_job" "maintenance" {
  name     = "plunk-maintenance"
  project  = var.project_id
  location = var.region

  # See api.tf for why this is off during bootstrap.
  deletion_protection = false

  labels = merge(local.common_labels, {
    component = "maintenance"
  })

  template {
    template {
      # Dedicated runtime identity (iam.tf) — grants exactly the Secret
      # Manager access this job needs instead of the shared per-project
      # default compute service account.
      service_account = google_service_account.maintenance.email

      containers {
        image = var.maintenance_image

        resources {
          limits = {
            cpu    = var.maintenance_cpu
            memory = var.maintenance_memory
          }
        }

        dynamic "env" {
          for_each = var.maintenance_env_vars
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.maintenance_secret_env_vars
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
  }

  # See api.tf for why image changes are ignored here — cloudbuild.yaml's
  # `update-maintenance-job` step keeps this pointed at the latest api image.
  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }

  # See api.tf for why this depends on the time_sleep rather than the IAM
  # grant directly.
  depends_on = [time_sleep.maintenance_secret_iam_propagation]
}

# --- Cloud Scheduler: one entry per maintenance task ------------------------
# All UTC — a container's local time defaults to UTC (matches today's BullMQ
# repeatable-job cadence, which also runs in UTC), verify this against the
# maintenance-runner image at deploy time if that default is ever overridden.
locals {
  maintenance_schedules = {
    "domain-verification"     = "*/5 * * * *"
    "segment-count"           = "*/5 * * * *"
    "api-request-cleanup"     = "0 3 * * *"
    "idempotency-key-cleanup" = "0 * * * *"
    "email-body-cleanup"      = "0 4 * * *"
  }
}

# Dedicated identity for Cloud Scheduler itself — separate from
# google_service_account.maintenance (the Job's own runtime identity while
# it's executing). This one only ever needs roles/run.invoker on
# plunk-maintenance, granted below, and nothing else.
resource "google_service_account" "scheduler" {
  project      = var.project_id
  account_id   = "plunk-scheduler-run"
  display_name = "Plunk Cloud Scheduler (invokes plunk-maintenance)"

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_job_iam_member" "maintenance_scheduler_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_job.maintenance.location
  name     = google_cloud_run_v2_job.maintenance.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "maintenance" {
  for_each = local.maintenance_schedules

  name      = "plunk-maintenance-${each.key}"
  project   = var.project_id
  region    = var.region
  schedule  = each.value
  time_zone = "UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.maintenance.name}:run"

    headers = {
      "Content-Type" = "application/json"
    }

    # containerOverrides.args is what selects which of the 5 tasks this
    # particular schedule runs — see maintenance-runner.ts's --task= parsing.
    body = base64encode(jsonencode({
      overrides = {
        containerOverrides = [
          {
            args = ["--task=${each.key}"]
          }
        ]
      }
    }))

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.maintenance_scheduler_invoker]
}
