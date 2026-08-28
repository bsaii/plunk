# plunk-api — min_instance_count defaults to 0 (scale-to-zero); cpu_idle is
# false (CPU always allocated while an instance is warm). This used to be an
# always-warm instance with CPU always allocated, kept that way as a
# correctness crutch: workflow execution used to run synchronously (and, in
# one path, fire-and-forget) inside HTTP request handlers, which is unsafe
# once CPU can be throttled after the response is sent. That part's fixed
# (see WorkflowExecutionService.ts, EventService.ts, WorkflowService.ts, and
# the requestLogger.ts/idempotency.ts middleware, which now complete their DB
# writes before the response is flushed rather than after), so
# min_instance_count was safe to drop to 0.
#
# cpu_idle stays false, though: apps/api/src/database/redis.ts holds a single
# long-lived `rediss://` connection reused across requests. With CPU only
# allocated during request processing, an in-flight TLS handshake/reconnect
# can get frozen mid-flight the instant a response is sent, and ioredis's
# connect-timeout timer is wall-clock (not CPU-time) — so by the time the
# next request thaws the instance, the timer has already "expired" and fires
# immediately as `connect ETIMEDOUT`, even though nothing was truly stuck.
# This bit us in production; don't flip this back without giving the Redis
# client a request-scoped connection lifecycle first.
#
# Cold starts cost a few seconds of Node/Prisma boot latency after an idle
# period; raise api_min_instance_count back to 1 (terraform.tfvars) once this
# deployment carries enough traffic that an always-warm instance pays for
# itself.
# Public internet ingress: Cloudflare proxies api_domain
# straight to this service (see dns.tf's domain mapping) rather than routing
# through a GCP load balancer, so this can't be restricted to
# INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER — there is no GCP-internal path from
# Cloudflare's edge to Cloud Run.
resource "google_cloud_run_v2_service" "api" {
  name     = "plunk-api"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  # Defaults to true in the provider — off here since this whole directory
  # targets a brand-new project with nothing serving real traffic yet (see
  # the header of this directory's README); a botched first create (e.g.
  # the IAM-propagation race iam.tf's time_sleep resources work around) is
  # more likely at this stage than an accidental destroy worth guarding
  # against. Worth flipping back to true (or just deleting this line) once
  # this is a stable deployment with real users.
  deletion_protection = false

  labels = merge(local.common_labels, {
    component = "api"
  })

  template {
    scaling {
      min_instance_count = var.api_min_instance_count
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
        # Explicit rather than relying on the provider default (see the
        # header comment above) — CPU always allocated, not just while
        # handling a request, so the persistent Redis connection doesn't get
        # frozen mid-handshake between requests.
        cpu_idle = false
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
