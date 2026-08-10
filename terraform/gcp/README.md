# Plunk — GCP Terraform

Manages `plunk-api`, `plunk-web`, the `plunk-migrate` Cloud Run Job, the `plunk-worker` Cloud Run
Worker Pool, and the Global External HTTPS Load Balancer that fronts the two services with custom
domains — plus everything a brand-new GCP project needs before any of that can exist: the
required APIs, the Artifact Registry repo, and every runtime/build service account and IAM
binding (`services.tf` / `iam.tf`). Written for a fresh project with nothing deployed yet — if
`plunk-api`/`plunk-web`/`plunk-migrate`/the Artifact Registry repo already exist in your target
project, see "If ... already exist" under Usage below before running `terraform apply`.

## Division of labor with `cloudbuild.yaml`

`cloudbuild.yaml` (repo root) still owns building and rolling out container images on every
merge (`gcloud run deploy` / `gcloud run jobs update` / `gcloud run worker-pools update`). This
Terraform owns everything else: the APIs and Artifact Registry repo Cloud Build pushes into
(`services.tf`), every service account and IAM grant Cloud Build and the Cloud Run resources
themselves need (`iam.tf`), scaling (`min_instance_count`/`max_instance_count`), CPU/memory,
ingress, the load balancer, TLS, and labels. Each Cloud Run resource's `lifecycle.ignore_changes`
on its image field is what keeps the two from fighting — `terraform apply` will never revert an
image Cloud Build just deployed.

## Why a load balancer instead of `gcloud run domain-mappings`

Direct Cloud Run domain mappings are still a Preview feature and Google does not recommend them
for production (see [Mapping custom domains](https://cloud.google.com/run/docs/mapping-custom-domains)).
`lb.tf` instead provisions a Global External Application Load Balancer: one reserved static IP,
one Google-managed TLS certificate covering both `api_domain` and `web_domain`, and host-based
routing via serverless NEGs. See [Google's serverless NEG load balancer guide](https://cloud.google.com/load-balancing/docs/https/setup-global-ext-https-serverless)
for the underlying architecture.

Both Cloud Run services are set to `ingress = INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`, so they
can no longer be reached directly via their `*.run.app` URL — only through the load balancer.
The `roles/run.invoker` → `allUsers` IAM binding stays in place (needed for the load balancer to
invoke them; Plunk does its own app-level auth on top).

## Prerequisites this Terraform provisions (`services.tf`, `iam.tf`)

On a brand-new GCP project there is nothing to click through in the console first:

- **`services.tf`** enables every required API (`run`, `artifactregistry`, `secretmanager`, `iam`,
  `cloudbuild`, `compute`, `cloudresourcemanager`) with `disable_on_destroy = false`, and creates
  the `plunk` Artifact Registry Docker repo that `cloudbuild.yaml` pushes `api`/`web`/`worker`
  images into.
- **`iam.tf`** creates a dedicated runtime service account per Cloud Run resource
  (`plunk-api-run`, `plunk-web-run`, `plunk-migrate-run`, `plunk-worker-run`) instead of relying on
  the shared per-project default compute service account, and grants each one
  `roles/secretmanager.secretAccessor` scoped to exactly the secrets its own `*_secret_env_vars`
  map references — required for Cloud Run to resolve a `secret_key_ref` env var at container
  start (see [Google's secret access requirement](https://cloud.google.com/run/docs/configuring/secrets#access-secret)).
  It also grants the **existing** Cloud Build service account
  (`plunk-cloud-build@<project>.iam.gserviceaccount.com` — a user-managed account per Google's
  current recommendation, not the legacy `PROJECT_NUMBER@cloudbuild.gserviceaccount.com` default;
  see `docs/deploy-cloud-build.md`) `roles/run.admin`, `roles/logging.logWriter`, repo-scoped
  `roles/artifactregistry.writer`, and `roles/iam.serviceAccountUser` on each runtime service
  account individually. The Cloud Build service account itself is **not** created here — it must
  already exist; this file only grants it IAM roles.

## Labels

Every Cloud Run service/job/worker-pool resource gets two labels (`api.tf`, `web.tf`,
`migrate.tf`, `worker.tf`); the Artifact Registry repo (`services.tf`) gets the `environment`
label alone. IAM resources (service accounts, IAM bindings) and the load balancer's networking
resources (`lb.tf`) do **not** carry these labels — Cloud IAM resources don't support labels at
all, and the LB pieces were a deliberate scope decision, not an oversight:

| Label | Value | Purpose |
| --- | --- | --- |
| `environment` | `var.environment` | Separates cost/queries per environment if this project ever hosts more than one (production, staging, ...). |
| `component` | `api` / `web` / `migrate` / `worker` | Breaks down Cloud Billing cost reports and `gcloud ... --filter="labels.component=api"` queries per piece of infrastructure instead of one lump sum. |

## Usage

```bash
cd terraform/gcp

terraform init \
  -backend-config="bucket=<your-terraform-state-bucket>" \
  -backend-config="prefix=plunk/gcp/<environment>"

terraform plan -var-file=production.tfvars -out=production.tfplan
terraform show -no-color production.tfplan   # review before applying — first apply creates
                                              # every resource in this directory from scratch
terraform apply production.tfplan
```

`production.tfvars` pins `project_id`, `api_domain`/`web_domain`, explicit CPU/memory/max-instance
sizing per component, and the non-secret/secret env var maps — see that file's comments. For a
new/non-production environment, add a matching `<environment>.tfvars` rather than passing ad-hoc
`-var` flags (same reasoning as `terraform/aws/README.md`'s equivalent section).

Non-secret env vars go in `api_env_vars` / `web_env_vars` / `migrate_env_vars` / `worker_env_vars`
(plain maps). Secret values (`JWT_SECRET`, `DATABASE_URL`, AWS keys, etc.) go in
`api_secret_env_vars` / `web_secret_env_vars` / `migrate_secret_env_vars` / `worker_secret_env_vars`
as `{ ENV_VAR_NAME = "secret-manager-secret-id" }` — Terraform only ever references the secret by
name (always version `latest`), so no secret value enters `.tf`/`.tfvars` files or Terraform
state. The referenced secrets must already exist in Secret Manager; `iam.tf` grants each runtime
service account access to exactly the ones its own map references.

### `.terraform.lock.hcl`

Not committed yet — unlike `terraform/aws`, this lock file couldn't be generated in the
environment this Terraform was authored in (no route to `registry.terraform.io` to download the
`hashicorp/google` provider and hash it). Run `terraform init` once from an environment with
normal internet access and commit the `.terraform.lock.hcl` it produces before the first real
`apply`, exactly like `terraform/aws/.terraform.lock.hcl`.

### If `plunk-api`/`plunk-web`/`plunk-migrate` (or the `plunk` Artifact Registry repo) already exist

This Terraform is written for a project where none of it has been deployed yet — the default
assumption throughout this README. **Before your first `apply`, confirm which case you're in**:

```bash
gcloud artifacts repositories describe plunk --location=us-central1 --project=<your-project-id>
gcloud run services list --region=us-central1 --project=<your-project-id>
gcloud run jobs list --region=us-central1 --project=<your-project-id>
gcloud run worker-pools list --region=us-central1 --project=<your-project-id>
```

If any of those come back non-empty, do **not** run `terraform apply` yet — it would try to
*create* a resource with a name that already exists and fail on the collision. Import each one
that already exists first:

```bash
cd terraform/gcp

terraform import -var-file=production.tfvars \
  google_artifact_registry_repository.plunk \
  "projects/<your-project-id>/locations/us-central1/repositories/plunk"

terraform import -var-file=production.tfvars \
  google_cloud_run_v2_service.api \
  "projects/<your-project-id>/locations/us-central1/services/plunk-api"

terraform import -var-file=production.tfvars \
  google_cloud_run_v2_service.web \
  "projects/<your-project-id>/locations/us-central1/services/plunk-web"

terraform import -var-file=production.tfvars \
  google_cloud_run_v2_job.migrate \
  "projects/<your-project-id>/locations/us-central1/jobs/plunk-migrate"

# Only if plunk-worker already exists too — most first-time setups won't have this yet
# (the worker was previously undeployed/TBD, see git history):
terraform import -var-file=production.tfvars \
  google_cloud_run_v2_worker_pool.worker \
  "projects/<your-project-id>/locations/us-central1/workerPools/plunk-worker"
```

Then `terraform plan` and read the diff carefully before applying — importing only makes
Terraform aware of the resource's *current* state; it does not by itself change anything.

**If `plunk-api`/`plunk-web` are live and serving real traffic when you import them**, the plan
will include flipping `ingress` from whatever it is today to
`INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` (see "Why a load balancer" above) — that cuts off the
direct `*.run.app` URL the moment it applies. Don't apply that change until the load balancer's
DNS records are live and `ssl_certificate_status` reads `ACTIVE` (see "After apply" below),
or traffic on the old URL breaks before the new path is ready. Practically: apply everything
*except* the ingress flip first (`terraform apply -target=... ` for the non-ingress resources, or
temporarily hardcode `ingress = "INGRESS_TRAFFIC_ALL"` and revert once DNS/cert are confirmed),
then cut over.

## After `apply`: DNS and certificate provisioning

1. Read the `load_balancer_ip` output.
2. At your DNS registrar, add `A` records for both `api_domain` and `web_domain` pointing at
   that IP.
3. Wait for DNS to propagate, then poll `ssl_certificate_status` (or check Certificate Manager
   in the console) until it reads `ACTIVE` — it stays `PROVISIONING` until DNS resolves.
4. Once the certificate is active, update `API_URI` / `DASHBOARD_URI` (and the matching
   `NEXT_PUBLIC_*` values baked into the web build) to the new `https://` domains, and update the
   SES/SNS webhook subscription to `https://<api_domain>/webhooks/sns`.

## Resource inventory (for a GCP Pricing Calculator estimate)

| # | Resource | Type | Notes |
| --- | --- | --- | --- |
| 1 | `plunk-api` | Cloud Run v2 service | `min_instance_count=1`, `1 vCPU`/`512Mi` by default — at least one instance billed continuously (CPU+memory), plus per-request beyond that |
| 2 | `plunk-web` | Cloud Run v2 service | `min_instance_count=0`, `1 vCPU`/`512Mi` by default — billed only while serving requests (scale-to-zero) |
| 3 | `plunk-migrate` | Cloud Run v2 Job | Billed only on manual execution; effectively $0 at rest |
| 4 | `plunk-worker` | Cloud Run v2 Worker Pool | Fixed `manual_instance_count=1` (Worker Pools don't autoscale on load the way a Cloud Run service does), `1 vCPU`/`512Mi` by default — always-on, no request-based tier (no HTTP entrypoint); ≈$62–68/month baseline for the one always-on instance at current Tier-1 rates, verify against the calculator; raise `worker_instance_count` by hand (and `worker_memory` if needed) as queue throughput grows |
| 5 | `plunk` Artifact Registry repo | Docker repo | Storage (per GB of stored image layers) + minor egress; no direct charge for the repo itself |
| 6 | `plunk-lb-ip` | Global static external IP | Small hourly reservation charge (Premium tier) |
| 7 | `plunk-cert` | Managed SSL certificate | No direct charge |
| 8 | `plunk-api-neg`, `plunk-web-neg` | Serverless NEGs (x2) | No direct charge (routing config only) |
| 9 | `plunk-api-backend`, `plunk-web-backend` | Backend services (x2) | No direct charge; LB request/data-processing charges apply at the forwarding-rule level |
| 10 | `plunk-lb`, `plunk-http-redirect` | URL maps (x2) | No direct charge |
| 11 | `plunk-https-proxy`, `plunk-http-proxy` | Target proxies (x2) | No direct charge |
| 12 | `plunk-https`, `plunk-http` | Global forwarding rules (x2) | **Primary load balancer cost driver**: hourly forwarding-rule charge + per-GB data-processing charge |
| 13 | Runtime service accounts (x4) + Cloud Build IAM bindings | `google_service_account`, `google_*_iam_member` | No charge — IAM has no usage-based cost |
| 14 | IAM invoker bindings | `google_cloud_run_v2_service_iam_member` (x2) | No charge |
| 15 | Secret Manager secret access | References only — secrets pre-exist | Per-access-op charges only, negligible at this scale |

The three biggest cost levers to check against the pricing calculator before applying: `plunk-api`
(`min_instance_count=1`) and `plunk-worker` (fixed `manual_instance_count=1`) both running an
always-on instance continuously, and the load balancer's forwarding rules (billed hourly
regardless of traffic, plus per-GB processed).

## Out of scope

- DNS record management (Namecheap or otherwise) — stays a manual step, see above.
- `landing` / `wiki` domains and services — not yet built in `Dockerfile.services` or wired into
  `cloudbuild.yaml`, so not in this Terraform either.
- The Cloud Build service account's own creation (`gcloud iam service-accounts create
  plunk-cloud-build`) — `iam.tf` grants it IAM roles but does not create the account itself, since
  it's expected to already exist (see `docs/deploy-cloud-build.md`).
- Automatically detecting and importing pre-existing `plunk-api`/`plunk-web`/`plunk-migrate`/
  `plunk-worker`/Artifact Registry resources — this Terraform assumes a project where nothing has
  been deployed yet; see "If ... already exist" under Usage above for the manual check + import
  commands if that assumption doesn't hold for your project.
