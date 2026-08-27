# GCP operations

## Cloud Tasks

In Google Cloud Console, open **Cloud Tasks** and select the deployment region. The nine queues must be `RUNNING`: `email-transactional`, `email-workflow`, `email-campaign`, `campaign`, `scheduled`, `workflow`, `import`, `bulk-contact-actions`, and `meter`.

A temporary non-zero queue depth during work is normal. It must drain after the worker responds. Use Monitoring > Metrics Explorer with **Cloud Tasks Queue**:
- **Queue depth**: should not continually rise.
- **Task attempt count**, grouped by response code: `ok` confirms successful deliveries; non-`ok` responses indicate retries or failures.

Cloud Tasks removes completed tasks, so confirm processing in Cloud Run > `plunk-worker` > Logs. Successful task requests return HTTP `204`; `401` means OIDC configuration is wrong and `500` causes retry. The internal worker should scale back to zero while idle.

## Cloud Scheduler maintenance

In Google Cloud Console, open **Cloud Scheduler** in the deployment region. The five `plunk-maintenance-*` jobs must be **Enabled**, have a future next-run time, and show a successful last run.

Then open Cloud Run > Jobs > `plunk-maintenance` > Executions. Each scheduler dispatch should create a successful execution. For a controlled smoke test, use **Force run** on `plunk-maintenance-domain-verification`, then confirm its resulting execution succeeds. Do not force-run cleanup jobs merely for a smoke test.

## Deployment

The production Cloud Build trigger is the only deployment path. It builds from the connected GitHub repository and deploys the API, web dashboard, maintenance job, and internal Cloud Tasks worker. Do not use `gcloud builds submit` for normal production deploys.
