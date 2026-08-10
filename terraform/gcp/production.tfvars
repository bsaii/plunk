# Production values for the GCP Cloud Run + load balancer stack.
#
# project_id matches the GCP project the plunk-cloud-build service account
# already lives in (plunk-cloud-build@saii-407116.iam.gserviceaccount.com —
# see docs/deploy-cloud-build.md and iam.tf's cloud_build_service_account_id).
# Confirm this is still correct against the GCP console before relying on it
# — unlike terraform/aws/production.tfvars's bucket_name (pinned against an
# already-running distribution), nothing in this GCP project has been
# deployed yet, so there is no live resource to cross-check it against.
#
# api_domain / web_domain match the hosted Plunk instance's real subdomains
# (see .env.self-host.example, CONTRIBUTING.md). Contains no credentials —
# safe to commit. Secret values referenced in *_secret_env_vars below are
# Secret Manager secret IDs only (never the secret material itself) and MUST
# already exist in Secret Manager before `terraform apply` — see this
# directory's README.
project_id  = "saii-407116"
region      = "us-central1"
environment = "production"

api_domain = "next-api.useplunk.com"
web_domain = "next-app.useplunk.com"

# --- Explicit compute sizing --------------------------------------------
# Pinned here (rather than left to variables.tf's defaults) so `terraform
# plan` is always the source of truth for what's actually provisioned, per
# this directory's README. Adjust after checking real usage against the
# GCP Pricing Calculator / Cloud Monitoring.
api_cpu                = "1"
api_memory             = "512Mi"
api_max_instance_count = 10

web_cpu                = "1"
web_memory             = "512Mi"
web_max_instance_count = 10

migrate_cpu    = "1"
migrate_memory = "512Mi"

worker_cpu                = "1"
worker_memory             = "512Mi"
worker_min_instance_count = 1
worker_max_instance_count = 3

# --- Non-secret environment variables -----------------------------------

api_env_vars = {
  NODE_ENV      = "production"
  API_URI       = "https://next-api.useplunk.com"
  DASHBOARD_URI = "https://next-app.useplunk.com"
  LANDING_URI   = "https://www.useplunk.com"
  WIKI_URI      = "https://docs.useplunk.com"
}

web_env_vars = {
  API_URI       = "https://next-api.useplunk.com"
  DASHBOARD_URI = "https://next-app.useplunk.com"
  LANDING_URI   = "https://www.useplunk.com"
  WIKI_URI      = "https://docs.useplunk.com"
}

migrate_env_vars = {
  NODE_ENV = "production"
}

# Worker env vars are a SUBSET of the API's — see docs/deploy-cloud-build.md's
# "Worker environment variables" section for exactly which ones and why
# (S3_*, OAuth, Stripe price IDs, etc. are HTTP-only and never imported by
# the worker's code path).
worker_env_vars = {
  NODE_ENV      = "production"
  API_URI       = "https://next-api.useplunk.com"
  DASHBOARD_URI = "https://next-app.useplunk.com"
  LANDING_URI   = "https://www.useplunk.com"
  WIKI_URI      = "https://docs.useplunk.com"
}

# --- Secret environment variables ---------------------------------------
# Map values are Secret Manager secret IDs (short names, not full resource
# paths) — create each one first, e.g.:
#   gcloud secrets create plunk-jwt-secret --replication-policy=automatic
#   echo -n "<value>" | gcloud secrets versions add plunk-jwt-secret --data-file=-
# iam.tf grants each runtime service account roles/secretmanager.secretAccessor
# scoped to exactly the secrets referenced below — nothing broader.

api_secret_env_vars = {
  JWT_SECRET                = "plunk-jwt-secret"
  DATABASE_URL              = "plunk-database-url"
  DIRECT_DATABASE_URL       = "plunk-direct-database-url"
  REDIS_URL                 = "plunk-redis-url"
  AWS_SES_ACCESS_KEY_ID     = "plunk-ses-access-key-id"
  AWS_SES_SECRET_ACCESS_KEY = "plunk-ses-secret-access-key"
  S3_ACCESS_KEY_ID          = "plunk-s3-access-key-id"
  S3_ACCESS_KEY_SECRET      = "plunk-s3-access-key-secret"
  STRIPE_SK                 = "plunk-stripe-sk"
  STRIPE_WEBHOOK_SECRET     = "plunk-stripe-webhook-secret"
}

# The dashboard is a pure frontend (no DB/Redis/S3 credentials — see
# docs/deploy-cloud-run.md) — nothing to reference here.
web_secret_env_vars = {}

migrate_secret_env_vars = {
  DATABASE_URL        = "plunk-database-url"
  DIRECT_DATABASE_URL = "plunk-direct-database-url"
}

worker_secret_env_vars = {
  JWT_SECRET                = "plunk-jwt-secret"
  DATABASE_URL              = "plunk-database-url"
  DIRECT_DATABASE_URL       = "plunk-direct-database-url"
  REDIS_URL                 = "plunk-redis-url"
  AWS_SES_ACCESS_KEY_ID     = "plunk-ses-access-key-id"
  AWS_SES_SECRET_ACCESS_KEY = "plunk-ses-secret-access-key"
}
