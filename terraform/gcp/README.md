# Plunk — GCP Terraform

Manages `plunk-api`, `plunk-web`, the `plunk-migrate` Cloud Run Job, and the Global External
HTTPS Load Balancer that fronts the two services with custom domains.

## Division of labor with `cloudbuild.yaml`

`cloudbuild.yaml` (repo root) still owns building and rolling out container images on every
merge (`gcloud run deploy` / `gcloud run jobs update`). This Terraform owns everything else:
scaling (`min_instance_count`), ingress, the load balancer, TLS, labels, and IAM. Each Cloud Run
resource's `lifecycle.ignore_changes` on its image field is what keeps the two from fighting —
`terraform apply` will never revert an image Cloud Build just deployed.

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

## Labels

Every resource gets two labels:

| Label | Value | Purpose |
| --- | --- | --- |
| `environment` | `var.environment` | Separates cost/queries per environment if this project ever hosts more than one (production, staging, ...). |
| `component` | `api` / `web` / `migrate` | Breaks down Cloud Billing cost reports and `gcloud ... --filter="labels.component=api"` queries per piece of infrastructure instead of one lump sum. |

## Usage

```bash
cd terraform/gcp

terraform init \
  -backend-config="bucket=<your-terraform-state-bucket>" \
  -backend-config="prefix=plunk/gcp/<environment>"

terraform plan \
  -var="project_id=<your-project-id>" \
  -var="api_domain=plunk-api.example.com" \
  -var="web_domain=plunk-app.example.com"

terraform apply ...
```

Non-secret env vars go in `api_env_vars` / `web_env_vars` / `migrate_env_vars` (plain maps).
Secret values (`JWT_SECRET`, `DATABASE_URL`, AWS keys, etc.) go in `api_secret_env_vars` /
`web_secret_env_vars` / `migrate_secret_env_vars` as `{ ENV_VAR_NAME = "secret-manager-secret-id" }`
— Terraform only ever references the secret by name (always version `latest`), so no secret
value enters `.tf`/`.tfvars` files or Terraform state. The referenced secrets must already exist
in Secret Manager.

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
| 1 | `plunk-api` | Cloud Run v2 service | `min_instance_count=1` — at least one instance billed continuously (CPU+memory), plus per-request beyond that |
| 2 | `plunk-web` | Cloud Run v2 service | `min_instance_count=0` — billed only while serving requests (scale-to-zero) |
| 3 | `plunk-migrate` | Cloud Run v2 Job | Billed only on manual execution; effectively $0 at rest |
| 4 | `plunk-lb-ip` | Global static external IP | Small hourly reservation charge (Premium tier) |
| 5 | `plunk-cert` | Managed SSL certificate | No direct charge |
| 6 | `plunk-api-neg`, `plunk-web-neg` | Serverless NEGs (x2) | No direct charge (routing config only) |
| 7 | `plunk-api-backend`, `plunk-web-backend` | Backend services (x2) | No direct charge; LB request/data-processing charges apply at the forwarding-rule level |
| 8 | `plunk-lb`, `plunk-http-redirect` | URL maps (x2) | No direct charge |
| 9 | `plunk-https-proxy`, `plunk-http-proxy` | Target proxies (x2) | No direct charge |
| 10 | `plunk-https`, `plunk-http` | Global forwarding rules (x2) | **Primary load balancer cost driver**: hourly forwarding-rule charge + per-GB data-processing charge |
| 11 | IAM invoker bindings | `google_cloud_run_v2_service_iam_member` (x2) | No charge |
| 12 | Secret Manager secret access | References only — secrets pre-exist | Per-access-op charges only, negligible at this scale |

The two biggest cost levers to check against the pricing calculator before applying: `plunk-api`
running with `min_instance_count=1` (always-on CPU/memory), and the load balancer's forwarding
rules (billed hourly regardless of traffic, plus per-GB processed).

## Out of scope

- The BullMQ worker's Cloud Run Worker Pool — dropped from both Cloud Build and this Terraform;
  its deployment strategy is a separate, currently-undecided piece of work.
- DNS record management (Namecheap or otherwise) — stays a manual step, see above.
- `landing` / `wiki` domains and services — not yet built in `Dockerfile.services` or wired into
  `cloudbuild.yaml`, so not in this Terraform either.
