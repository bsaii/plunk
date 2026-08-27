# Phase 3's provisioning apply is deliberately non-disruptive. Keep this
# false while REALTIME_QUEUE_BACKEND remains bullmq. Change it only in the
# same reviewed cutover that sets REALTIME_QUEUE_BACKEND=cloud-tasks on the
# API; it removes the legacy Worker Pool after the Cloud Tasks worker is live.
variable "remove_legacy_worker_pool" {
  description = "Destroy the legacy plunk-worker BullMQ Worker Pool after Cloud Tasks real-time processing is active."
  type        = bool
  default     = false
}

variable "worker_max_instance_count" {
  description = "Maximum autoscaled instance count for the internal Cloud Tasks worker service."
  type        = number
  default     = 10
}
