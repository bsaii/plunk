# Plunk — GCP Terraform

Manages `plunk-api`, `plunk-web`, the `plunk-migrate` Cloud Run Job, the `plunk-worker` Cloud Run
Worker Pool, and the Global External HTTPS Load Balancer that fronts the two services with custom
domains — plus everything the brand-new GCP project this targets needs before any of that can
exist: the required APIs, the Artifact Registry repo, and every runtime/build service account and
IAM binding (`services.tf` / `iam.tf`). Nothing in this project has been deployed yet — every
`google_cloud_run_v2_*`/`google_artifact_registry_repository` resource here is a first-time
`create`, not an update to something already running, so no `terraform import` step is needed
before the first `apply`.

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

## Usage: bootstrapping a brand-new GCP project

Everything below assumes a **fresh GCP project with nothing in it** — the target this whole
directory is designed for. Run it from GCP Cloud Shell (or any shell authenticated as a
user/service account with roughly Owner-equivalent rights on the project — Cloud Shell's default
`gcloud auth` identity is normally enough). Cloud Shell has **no AWS credentials**: steps that need
an AWS-sourced value say so explicitly and expect you to fetch it separately (your own workstation,
or `terraform output` in `terraform/aws`) rather than from this environment.

### 0. Point `gcloud` at the project and confirm billing

```bash
export PROJECT_ID="your-gcp-project-id"
gcloud config set project "$PROJECT_ID"

# A brand-new project has no billing account linked yet — Cloud Run, the load
# balancer, and Secret Manager all require one. Check first:
gcloud billing projects describe "$PROJECT_ID"
# If it shows billingEnabled: false, link one (get the ID from `gcloud billing accounts list`):
gcloud billing projects link "$PROJECT_ID" --billing-account=YOUR_BILLING_ACCOUNT_ID

# serviceusage.googleapis.com must itself be enabled before Terraform can
# enable everything else in services.tf.
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com
```

### 1. Create the Terraform state bucket

Not managed by this Terraform — a backend can't bootstrap its own storage — so create it once, by
hand, before the first `terraform init`. GCS bucket names are global across all of Google Cloud, so
pick something unlikely to collide:

```bash
export STATE_BUCKET="${PROJECT_ID}-plunk-tfstate"

gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --project="$PROJECT_ID" \
  --location=us-central1 \
  --uniform-bucket-level-access

# Versioning lets you recover a previous state file if an apply ever
# corrupts or truncates the current one.
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
```

### 2. Create the Cloud Build service account

`iam.tf` grants this account IAM roles but deliberately does not create it (see
`cloud_build_service_account_id` in `variables.tf` and the "Prerequisites" section above) —
Terraform shouldn't own an identity that `cloudbuild.yaml` also depends on existing independently
of any one `apply`/`destroy` cycle. Create it once, before the first `terraform apply` (`iam.tf`'s
IAM bindings on this account will fail to apply otherwise):

```bash
gcloud iam service-accounts create plunk-cloud-build \
  --project="$PROJECT_ID" \
  --display-name="Plunk Cloud Build"
```

### 3. Create the Secret Manager secrets

Terraform never creates or reads secret *values* — only IAM grants referencing secret IDs that
must already exist (see "Non-secret vs. secret env vars" below). Create every secret your
`*.tfvars`'s `*_secret_env_vars` maps reference before `terraform apply`, or `plan` will succeed
but `apply` will fail on the `google_secret_manager_secret_iam_member` resources with "Secret not
found".

The commands below match `production.tfvars` as committed. **Lines marked `(from AWS)` need a
value this Cloud Shell can't produce** — SES and S3 credentials live in AWS IAM. Create the secret
itself from here, then add its value from wherever you do have AWS access (see `terraform/aws`'s
README for the matching `aws iam create-access-key` step) — Secret Manager itself has no AWS
dependency, only the value being stored does.

```bash
for s in plunk-jwt-secret plunk-database-url plunk-direct-database-url plunk-redis-url \
         plunk-ses-access-key-id plunk-ses-secret-access-key \
         plunk-s3-access-key-id plunk-s3-access-key-secret \
         plunk-stripe-sk plunk-stripe-webhook-secret; do
  gcloud secrets create "$s" --project="$PROJECT_ID" --replication-policy=automatic
done

# Generate directly in Cloud Shell — no external dependency:
openssl rand -base64 32 | tr -d '\n' | gcloud secrets versions add plunk-jwt-secret --data-file=-

# From wherever your Postgres/Redis actually run — this Terraform doesn't
# provision either (Cloud SQL, Memorystore, or a third-party host, your call):
echo -n "postgresql://..." | gcloud secrets versions add plunk-database-url --data-file=-
echo -n "postgresql://..." | gcloud secrets versions add plunk-direct-database-url --data-file=-
echo -n "redis://..."      | gcloud secrets versions add plunk-redis-url --data-file=-

# (from AWS) SES IAM user credentials:
echo -n "AKIA..." | gcloud secrets versions add plunk-ses-access-key-id --data-file=-
echo -n "..."      | gcloud secrets versions add plunk-ses-secret-access-key --data-file=-

# (from AWS) S3 IAM user credentials — terraform/aws's iam.tf output plus
# `aws iam create-access-key`, see that directory's README:
echo -n "AKIA..." | gcloud secrets versions add plunk-s3-access-key-id --data-file=-
echo -n "..."      | gcloud secrets versions add plunk-s3-access-key-secret --data-file=-

# Stripe dashboard (optional — if not using billing yet, skip these two and
# delete the matching lines from production.tfvars's api_secret_env_vars
# instead of pre-creating throwaway secrets):
echo -n "sk_live_..." | gcloud secrets versions add plunk-stripe-sk --data-file=-
echo -n "whsec_..."   | gcloud secrets versions add plunk-stripe-webhook-secret --data-file=-
```

### 4. Fill in `production.tfvars`

The committed file is a template — every `REPLACE_WITH_*` placeholder (`project_id`,
`api_domain`/`web_domain`, and the AWS-sourced `S3_*`/`AWS_SES_REGION` values) needs a real value
before `terraform plan` will produce a sane plan; see the file's own comments for what each one
needs and which are safe defaults to leave alone. For a new/non-production environment, copy it to
a differently-named `<environment>.tfvars` instead of editing in place (same reasoning as
`terraform/aws/README.md`'s equivalent section).

Non-secret env vars go in `api_env_vars` / `web_env_vars` / `migrate_env_vars` / `worker_env_vars`
(plain maps). Secret values (`JWT_SECRET`, `DATABASE_URL`, AWS keys, etc.) go in
`api_secret_env_vars` / `web_secret_env_vars` / `migrate_secret_env_vars` / `worker_secret_env_vars`
as `{ ENV_VAR_NAME = "secret-manager-secret-id" }` — Terraform only ever references the secret by
name (always version `latest`), so no secret value enters `.tf`/`.tfvars` files or Terraform
state. The referenced secrets must already exist in Secret Manager (step 3); `iam.tf` grants each
runtime service account access to exactly the ones its own map references.

### 5. Init, plan, apply

```bash
cd terraform/gcp

terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=plunk/gcp/production"

terraform plan -var-file=production.tfvars -out=production.tfplan
terraform show -no-color production.tfplan   # review before applying — first apply creates
                                              # every resource in this directory from scratch
terraform apply production.tfplan
```

#### What to expect from `terraform plan`

Every resource in this directory is a first-time `create` (see the header of this file) — a
correct plan against a brand-new project shows **N to add, 0 to change, 0 to destroy**, and never
any `~` (in-place update) or `-` (destroy) line. Roughly, in the order Terraform will list them: 7
`google_project_service` API enablements, 1 Artifact Registry repo, 4 runtime service accounts, one
`google_secret_manager_secret_iam_member` per unique secret ID your tfvars' `*_secret_env_vars`
maps reference (10 unique IDs in the committed template → 18 grants split across api/migrate/
worker), 7 Cloud Build IAM grants, 2 Cloud Run services plus 2 `run.invoker` bindings, 1 Cloud Run
Job, 1 Cloud Run Worker Pool, and 12 load-balancer resources (the static IP, the managed
certificate, 2 serverless NEGs, 2 backend services, 2 URL maps, 2 target proxies, 2 forwarding
rules). That's around 55 resources total with the template's secret maps left as-is — the exact
count scales with how many secrets you end up referencing. If `plan` errors instead, it's almost
always one of: a secret from step 3 that doesn't exist yet, the Cloud Build service account from
step 2 missing, or `-backend-config` pointing at a state bucket that doesn't exist (step 1) —
`plan` itself never calls the Cloud Run/Secret Manager APIs, so a missing prerequisite only shows
up as a graph-build error, not a live API error.

#### What to expect from `terraform apply`

Takes a few minutes — the Cloud Run resources and the load balancer's global forwarding rules are
the slowest to provision. On success, Terraform prints every `outputs.tf` value: both services'
direct (LB-only, not internet-reachable) `*.run.app` URLs, the migrate job and worker pool names,
the Artifact Registry path, all five service account emails, `load_balancer_ip`, and
`ssl_certificate_name`. The managed SSL certificate does **not** become `ACTIVE` as part of
`apply` — it stays `PROVISIONING` until DNS for both domains resolves to `load_balancer_ip` (see
"After apply" below), which can take anywhere from minutes to a few hours after the DNS records go
in. The two Cloud Run services and the worker pool come up running the placeholder
`us-docker.pkg.dev/cloudrun/container/hello` image (`api_image`/`web_image`/`worker_image`'s
defaults) — they don't serve real Plunk traffic until you run `cloudbuild.yaml` at least once (see
`docs/deploy-cloud-build.md`), after which this Terraform's `lifecycle.ignore_changes` on the image
field leaves the deployed image alone on every subsequent `apply`.

### `.terraform.lock.hcl`

Committed, covering every platform in the `hashicorp/google` 6.37.0 release (darwin/linux/windows/
freebsd, amd64/arm64/386/arm as published) — regenerate it (`terraform init` from an environment
with a normal route to `registry.terraform.io`, or `terraform providers lock`) only if
`versions.tf`'s version constraint changes.

## After `apply`: DNS and certificate provisioning

1. Read the `load_balancer_ip` output.
2. At your DNS registrar, add `A` records for both `api_domain` and `web_domain` pointing at
   that IP.
3. Wait for DNS to propagate, then poll the certificate's status — the `hashicorp/google` provider
   doesn't expose it as a resource attribute, so check via `gcloud` instead of a Terraform output:
   ```bash
   gcloud compute ssl-certificates describe "$(terraform output -raw ssl_certificate_name)" \
     --format='value(managed.status,managed.domainStatus)'
   ```
   (or check Certificate Manager in the console) until it reads `ACTIVE` — it stays `PROVISIONING`
   until DNS resolves.
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
- The Cloud Build service account's own creation — `iam.tf` grants it IAM roles but does not
  create the account itself; that's a one-time `gcloud iam service-accounts create` step (see
  "Usage" step 2 above and `docs/deploy-cloud-build.md`), deliberately kept outside Terraform's
  ownership.
- Importing pre-existing resources — not applicable. This targets a brand-new GCP project with
  nothing deployed yet, so there is nothing to import.
