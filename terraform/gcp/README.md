# Plunk — GCP Terraform

Manages `plunk-api`, `plunk-web`, the `plunk-migrate` Cloud Run Job, and the `plunk-worker` Cloud
Run Worker Pool — plus everything the brand-new GCP project this targets needs before any of that
can exist: the required APIs, the Artifact Registry repo, and every runtime/build service account
and IAM binding (`services.tf` / `iam.tf`). Nothing in this project has been deployed yet — every
`google_cloud_run_v2_*`/`google_artifact_registry_repository` resource here is a first-time
`create`, not an update to something already running, so no `terraform import` step is needed
before the first `apply`.

## Division of labor with `cloudbuild.yaml`

`cloudbuild.yaml` (repo root) still owns building and rolling out container images on every
merge (`gcloud run deploy` / `gcloud run jobs update` / `gcloud run worker-pools update`). This
Terraform owns everything else: the APIs and Artifact Registry repo Cloud Build pushes into
(`services.tf`), every service account and IAM grant Cloud Build and the Cloud Run resources
themselves need (`iam.tf`), scaling (`min_instance_count`/`max_instance_count`), CPU/memory,
ingress, the Cloud Run Domain Mappings (`dns.tf`), and labels. Each Cloud Run resource's
`lifecycle.ignore_changes` on its image field is what keeps the two from fighting — `terraform
apply` will never revert an image Cloud Build just deployed.

## Traffic routing: Cloudflare proxy, not a GCP load balancer

`plunk-api` and `plunk-web` are reachable directly over the public internet
(`ingress = INGRESS_TRAFFIC_ALL` in `api.tf`/`web.tf`) — there is no Global External Load Balancer,
static IP, or managed certificate provisioned by this Terraform. Instead, `dns.tf` creates a Cloud
Run Domain Mapping per service, which is what lets Cloud Run itself recognize `api_domain`/
`web_domain`, issue a Google-managed certificate for each, and route requests by Host header to
the right service. Cloudflare sits in front as the actual proxy: its DNS record for each domain is
orange-clouded (proxied) and points at the record Google assigns the mapping (a CNAME to
`ghs.googlehosted.com` for a subdomain; A/AAAA records for an apex domain — see the
`*_domain_mapping_records` outputs). Cloudflare's SSL/TLS mode needs to be **Full** or **Full
(strict)** — Cloud Run always serves HTTPS, so **Flexible** would have Cloudflare talk plaintext
HTTP to an HTTPS-only origin and fail.

This means: no reserved static IP to pay for hourly, no load-balancer forwarding-rule charges, and
one fewer moving part between DNS and the service — at the cost of Google needing to verify you
own `api_domain`/`web_domain` before it will issue a certificate for the mapping (see "Usage"
below), and Domain Mappings being available in a smaller set of regions than the Cloud Run product
itself.

The `roles/run.invoker` → `allUsers` IAM binding on each service stays in place — with ingress
open to the whole internet, Cloud Run still requires an explicit grant to skip Google's own IAM
auth on incoming requests; Plunk does its own app-level auth on top of that.

## Prerequisites this Terraform provisions (`services.tf`, `iam.tf`)

On a brand-new GCP project there is nothing to click through in the console first:

- **`services.tf`** enables every required API (`run`, `artifactregistry`, `secretmanager`, `iam`,
  `cloudbuild`, `cloudresourcemanager`) with `disable_on_destroy = false`, and creates the `plunk`
  Artifact Registry Docker repo that `cloudbuild.yaml` pushes `api`/`web`/`worker` images into.
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
  already exist; this file only grants it IAM roles. `iam.tf` also has three `time_sleep` resources
  (`hashicorp/time` provider) that buffer 30s between granting `secretAccessor` and creating the
  Cloud Run resource that needs it — see that file's comment for the IAM-propagation race this
  works around.

## Labels

Every Cloud Run service/job/worker-pool resource gets two labels (`api.tf`, `web.tf`,
`migrate.tf`, `worker.tf`); the Artifact Registry repo (`services.tf`) gets the `environment`
label alone. IAM resources (service accounts, IAM bindings) and the Domain Mapping resources
(`dns.tf`) do **not** carry these labels — Cloud IAM resources don't support labels at all, and
the Domain Mappings weren't wired up with `metadata.labels` since nothing queries/bills on them
individually the way `component` does for the Cloud Run resources themselves:

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

# A brand-new project has no billing account linked yet — Cloud Run and
# Secret Manager both require one. Check first:
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

### 5. Verify domain ownership

The Domain Mapping resources in `dns.tf` will fail to create until `api_domain` and `web_domain`
are verified for the identity running Terraform (your `gcloud auth` user, or a service account) in
[Search Console](https://search.google.com/search-console) — Google won't issue a managed
certificate for a domain it can't confirm you own. Do this once per domain, before `apply`:

```bash
gcloud domains list-user-verified   # already-verified domains for the current identity, if any
```

If `api_domain`/`web_domain` (or their parent domain — verifying `example.com` covers every
subdomain) aren't listed, verify via Search Console → Add property → Domain, then follow its
DNS-TXT-record instructions at your registrar (this is a one-time proof of ownership, separate
from the Cloudflare records added after `apply`).

### 6. Init, plan, apply

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
any `~` (in-place update) or `-` (destroy) line. Roughly, in the order Terraform will list them: 6
`google_project_service` API enablements, 1 Artifact Registry repo, 4 runtime service accounts, one
`google_secret_manager_secret_iam_member` per unique secret ID your tfvars' `*_secret_env_vars`
maps reference (10 unique IDs in the committed template → 18 grants split across api/migrate/
worker), 3 `time_sleep` IAM-propagation buffers, 7 Cloud Build IAM grants, 2 Cloud Run services plus
2 `run.invoker` bindings, 1 Cloud Run Job, 1 Cloud Run Worker Pool, and 2 Cloud Run Domain Mappings
(`dns.tf`). That's around 47 resources total with the template's secret maps left as-is — the exact
count scales with how many secrets you end up referencing. If `plan` errors instead, it's almost
always one of: a secret from
step 3 that doesn't exist yet, the Cloud Build service account from step 2 missing, or
`-backend-config` pointing at a state bucket that doesn't exist (step 1) — `plan` itself never
calls the Cloud Run/Secret Manager APIs, so a missing prerequisite only shows up as a graph-build
error, not a live API error.

#### What to expect from `terraform apply`

Takes a couple of minutes for the Cloud Run resources themselves — including the (parallel, ~30s
each) `time_sleep` buffers between each secret's IAM grant and the resource that consumes it. The
two `google_cloud_run_domain_mapping`
resources can take noticeably longer (sometimes several minutes) since Google verifies domain
ownership and starts certificate issuance as part of creating them — `apply` doesn't return until
that create call completes, even though the certificate itself is still `PROVISIONING` at that
point (see "After apply" below). On success, Terraform prints every `outputs.tf` value: both
services' direct, publicly-reachable `*.run.app` URLs, the migrate job and worker pool names, the
Artifact Registry path, all five service account emails, and `api_domain_mapping_records` /
`web_domain_mapping_records` — the DNS records to hand Cloudflare. The two Cloud Run services and
the worker pool come up running the placeholder `us-docker.pkg.dev/cloudrun/container/hello` image
(`api_image`/`web_image`/`worker_image`'s defaults) — they don't serve real Plunk traffic until you
run `cloudbuild.yaml` at least once (see `docs/deploy-cloud-build.md`), after which this
Terraform's `lifecycle.ignore_changes` on the image field leaves the deployed image alone on every
subsequent `apply`.

If `apply` fails on either domain mapping with a verification/ownership error, go back to step 5
above and confirm that exact domain (not just its parent) shows up in
`gcloud domains list-user-verified`, then re-run `apply` — nothing else in the plan depends on the
mappings succeeding first, so a partial apply here is safe to resume.

### `.terraform.lock.hcl`

Committed, covering every platform in the `hashicorp/google` 6.37.0 release (darwin/linux/windows/
freebsd, amd64/arm64/386/arm as published) — regenerate it (`terraform init` from an environment
with a normal route to `registry.terraform.io`, or `terraform providers lock`) only if
`versions.tf`'s version constraint changes.

## After `apply`: Cloudflare DNS and certificate provisioning

1. Read the DNS records Google assigned each mapping:
   ```bash
   terraform output api_domain_mapping_records
   terraform output web_domain_mapping_records
   ```
   Each is a list of `{ name, rrdata, type }` — typically one `CNAME` record (`rrdata =
   ghs.googlehosted.com`) for a subdomain, or several `A`/`AAAA` records for an apex domain. If the
   output looks empty right after `apply`, the mapping's status hadn't propagated yet — re-run
   `terraform refresh` (or `gcloud run domain-mappings describe --domain=<api_domain>
   --region=<region>`) after a minute.
2. At Cloudflare, add the matching record(s) for `api_domain`/`web_domain` in the zone's DNS tab,
   **with the proxy status set to Proxied (orange cloud)** — a grey-clouded (DNS-only) record would
   send traffic straight to Google, bypassing Cloudflare entirely.
3. Set Cloudflare's SSL/TLS encryption mode to **Full** or **Full (strict)** for the zone (SSL/TLS
   → Overview) — Cloud Run has no plaintext HTTP listener, so **Flexible** breaks with a 526/502
   from Cloudflare.
4. Wait for Google's certificate to finish provisioning (substitute your actual `api_domain`/
   `web_domain` and `region`):
   ```bash
   gcloud run domain-mappings describe --domain=api.example.com \
     --region=us-central1 --format='value(status.conditions)'
   ```
   (or re-check the `*_domain_mapping_records` output / the Cloud Run console's "Domain Mappings"
   tab) until the `Ready`/`CertificateProvisioned` conditions read `True`. This depends on
   Cloudflare's DNS record from step 2 already being live — Google can't issue the certificate
   until it can resolve the domain.
5. Once both certificates are active, update `API_URI` / `DASHBOARD_URI` (and the matching
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
| 6 | `plunk-api`/`plunk-web` Domain Mappings | `google_cloud_run_domain_mapping` (x2) | No direct GCP charge — the managed certificate is free, same as the old load-balancer approach; Cloudflare's own plan/bandwidth costs apply separately and aren't a GCP Pricing Calculator line item |
| 7 | Runtime service accounts (x4) + Cloud Build IAM bindings | `google_service_account`, `google_*_iam_member` | No charge — IAM has no usage-based cost |
| 8 | IAM invoker bindings | `google_cloud_run_v2_service_iam_member` (x2) | No charge |
| 9 | Secret Manager secret access | References only — secrets pre-exist | Per-access-op charges only, negligible at this scale |

The two biggest cost levers to check against the pricing calculator before applying: `plunk-api`
(`min_instance_count=1`) and `plunk-worker` (fixed `manual_instance_count=1`) both running an
always-on instance continuously. There's no load-balancer forwarding-rule or reserved-IP charge in
this design — traffic goes DNS → Cloudflare → Cloud Run directly.

## Out of scope

- **Cloudflare configuration itself** — the DNS records, proxy (orange-cloud) status, and SSL/TLS
  mode described in "After apply" are set in the Cloudflare dashboard/API, which this Terraform
  (a `hashicorp/google`-only provider config) doesn't touch. If you want that declarative too,
  it's a separate `cloudflare` provider block in its own file, out of scope for this change.
- Domain ownership verification (Search Console) — a one-time, per-identity manual step; see
  "Usage" step 5.
- `landing` / `wiki` domains and services — not yet built in `Dockerfile.services` or wired into
  `cloudbuild.yaml`, so not in this Terraform either.
- The Cloud Build service account's own creation — `iam.tf` grants it IAM roles but does not
  create the account itself; that's a one-time `gcloud iam service-accounts create` step (see
  "Usage" step 2 above and `docs/deploy-cloud-build.md`), deliberately kept outside Terraform's
  ownership.
- Importing pre-existing resources — not applicable. This targets a brand-new GCP project with
  nothing deployed yet, so there is nothing to import.
