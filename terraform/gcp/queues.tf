# Cloud Tasks queues replace the seven real-time BullMQ queues. Email has
# three queues because Cloud Tasks has no per-task priority: transactional
# traffic is intentionally allowed the highest dispatch rate, workflow is
# next, and campaigns are capped so they cannot starve interactive mail.
locals {
  realtime_task_queues = {
    "email-transactional"  = { max_attempts = 3, min_backoff = "2s", max_dispatches_per_second = 100, max_concurrent_dispatches = 100 }
    "email-workflow"       = { max_attempts = 3, min_backoff = "2s", max_dispatches_per_second = 50, max_concurrent_dispatches = 50 }
    "email-campaign"       = { max_attempts = 3, min_backoff = "2s", max_dispatches_per_second = 10, max_concurrent_dispatches = 10 }
    "campaign"             = { max_attempts = 3, min_backoff = "5s", max_dispatches_per_second = 10, max_concurrent_dispatches = 10 }
    "scheduled"            = { max_attempts = 3, min_backoff = "10s", max_dispatches_per_second = 10, max_concurrent_dispatches = 10 }
    "workflow"             = { max_attempts = 3, min_backoff = "2s", max_dispatches_per_second = 25, max_concurrent_dispatches = 25 }
    "import"               = { max_attempts = 2, min_backoff = "5s", max_dispatches_per_second = 2, max_concurrent_dispatches = 2 }
    "bulk-contact-actions" = { max_attempts = 2, min_backoff = "5s", max_dispatches_per_second = 2, max_concurrent_dispatches = 2 }
    "meter"                = { max_attempts = 10, min_backoff = "5s", max_dispatches_per_second = 25, max_concurrent_dispatches = 25 }
  }

  cloud_tasks_enqueuer_bindings = {
    for pair in setproduct(keys(local.realtime_task_queues), [
      google_service_account.api.email,
      google_service_account.worker_service.email,
      ]) : "${pair[0]}-${pair[1]}" => {
      queue = pair[0]
      email = pair[1]
    }
  }
}

resource "google_cloud_tasks_queue" "realtime" {
  for_each = local.realtime_task_queues

  name     = each.key
  project  = var.project_id
  location = var.region

  rate_limits {
    max_dispatches_per_second = each.value.max_dispatches_per_second
    max_concurrent_dispatches = each.value.max_concurrent_dispatches
  }

  retry_config {
    max_attempts  = each.value.max_attempts
    min_backoff   = each.value.min_backoff
    max_backoff   = "3600s"
    max_doublings = 16
  }

  depends_on = [google_project_service.required]
}

resource "google_cloud_tasks_queue_iam_member" "realtime_enqueuer" {
  for_each = local.cloud_tasks_enqueuer_bindings

  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.realtime[each.value.queue].name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${each.value.email}"
}
