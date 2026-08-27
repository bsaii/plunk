# Cloud Tasks real-time worker cutover

Phase 3 replaces the always-on BullMQ Worker Pool with an internal Cloud Run
service that receives OIDC-authenticated Cloud Tasks deliveries. It removes
the Worker Pool's approximately $62–68/month idle baseline after cutover.

## Provision first

Keep both settings in their safe state for the first apply:

```hcl
# production.tfvars
remove_legacy_worker_pool = false

api_env_vars = {
  REALTIME_QUEUE_BACKEND = "bullmq"
  # Add the Cloud Tasks values after the worker service URL is known.
}
worker_env_vars = {
  REALTIME_QUEUE_BACKEND = "cloud-tasks"
}
```

Run Terraform, then record the emitted worker URL and invoker identity:

```bash
terraform apply -var-file=production.tfvars
terraform output worker_service_url
terraform output cloud_tasks_invoker_service_account_email
```

Add these non-secret values to both `api_env_vars` and `worker_env_vars`:

```hcl
CLOUD_TASKS_PROJECT_ID            = "<project id>"
CLOUD_TASKS_LOCATION              = "<region>"
CLOUD_TASKS_WORKER_URL            = "<worker_service_url>"
CLOUD_TASKS_AUDIENCE              = "<worker_service_url>"
CLOUD_TASKS_SERVICE_ACCOUNT_EMAIL = "<cloud_tasks_invoker service-account email>"
```

Apply once more, then deploy the worker-server image through Cloud Build. Keep
the API on `REALTIME_QUEUE_BACKEND=bullmq` during this provisioning stage.

## Cut over

After an authenticated task smoke test succeeds, make one reviewed Terraform
change:

```hcl
remove_legacy_worker_pool = true

api_env_vars = {
  REALTIME_QUEUE_BACKEND = "cloud-tasks"
  # retain the CLOUD_TASKS_* values above
}
```

Apply it. This updates the API configuration and removes the legacy Worker
Pool only after the Cloud Tasks service and queues exist. Roll back by setting
`REALTIME_QUEUE_BACKEND = "bullmq"` and `remove_legacy_worker_pool = false`
before applying; Terraform recreates the legacy pool from `worker_image`.

Do not grant `allUsers` on `plunk-worker`. Its ingress is internal-only and
only `plunk-cloud-tasks-invoker` has `roles/run.invoker`.
