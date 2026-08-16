# plunk-migrate — runs `prisma migrate deploy` off the api image. Terraform
# only ever creates/updates this Job's configuration; it is NEVER executed
# automatically from here (no Cloud Scheduler trigger, no null_resource /
# terraform_data running `jobs execute`). Applying migrations stays a
# deliberate manual step, exactly like today:
#   gcloud run jobs execute plunk-migrate --region=<region> --wait
resource "google_cloud_run_v2_job" "migrate" {
  name     = "plunk-migrate"
  project  = var.project_id
  location = var.region

  labels = merge(local.common_labels, {
    component = "migrate"
  })

  template {
    template {
      # Dedicated runtime identity (iam.tf) — grants exactly the Secret
      # Manager access this job needs instead of the shared per-project
      # default compute service account.
      service_account = google_service_account.migrate.email

      containers {
        image   = var.migrate_image
        command = ["node_modules/.bin/prisma"]
        args    = ["migrate", "deploy", "--schema=packages/db/prisma/schema.prisma"]

        resources {
          limits = {
            cpu    = var.migrate_cpu
            memory = var.migrate_memory
          }
        }

        dynamic "env" {
          for_each = var.migrate_env_vars
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.migrate_secret_env_vars
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
  # `update-migrate-job` step keeps this pointed at the latest api image.
  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }

  # See api.tf for why this explicit dependency is needed — Terraform has no
  # implicit edge to the Secret Manager IAM grant otherwise.
  depends_on = [google_secret_manager_secret_iam_member.migrate]
}
