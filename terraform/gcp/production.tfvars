# Template values for the GCP Cloud Run + load balancer stack.
#
# This targets a brand-new GCP project — nothing has been deployed yet, so
# nothing below can be pre-verified against a live resource (unlike
# terraform/aws/production.tfvars, which pins values against an
# already-running distribution). Replace every REPLACE_WITH_* placeholder
# before running `terraform plan`; everything else here (compute sizing,
# non-AWS env var names) is a sane default, not a project-specific fact.
#
# Values commented "(from AWS)" come from your AWS account / terraform/aws
# stack. If you're filling this in from GCP Cloud Shell, it has no AWS
# credentials — fetch these from wherever you do have AWS access (your own
# workstation, or `terraform output` in terraform/aws) and paste the plain
# (non-secret) values in here; the actual secret values never go in this
# file — see the *_secret_env_vars maps and this directory's README.
#
# Contains no credentials — safe to commit once every placeholder below is
# replaced with a real (non-secret) identifier.
project_id  = "saton-504611"
region      = "us-central1"
environment = "production"

api_domain = "plunk-api.saton.app"
web_domain = "plunk-web.saton.app"

# --- Explicit compute sizing --------------------------------------------
# Sane starting points, not project-specific — pinned here (rather than left
# to variables.tf's defaults) so `terraform plan` is always the source of
# truth for what's actually provisioned, per this directory's README. Adjust
# after checking real usage against the GCP Pricing Calculator / Cloud
# Monitoring.
api_cpu                = "1"
api_memory             = "512Mi"
api_max_instance_count = 10

web_cpu                = "1"
web_memory             = "512Mi"
web_max_instance_count = 10

migrate_cpu    = "1"
migrate_memory = "512Mi"

worker_cpu            = "1"
worker_memory         = "512Mi"
worker_instance_count = 1

# --- Non-secret environment variables -----------------------------------
# AWS_SES_REGION has no default in apps/api/src/app/constants.ts
# (validateEnv('AWS_SES_REGION') with no fallback) — omitting it crashes
# api/worker at boot.
#
# S3_* values point the API at wherever your uploads bucket actually lives
# instead of falling back to constants.ts's Minio-dev defaults
# (S3_ENDPOINT=http://minio:9000, S3_BUCKET=uploads,
# S3_FORCE_PATH_STYLE=true) — the last of those matters most: leaving it at
# the true/Minio default makes the API try to set a PUBLIC bucket policy on
# a real AWS S3 bucket at startup, fighting a private, CloudFront-scoped
# policy such as terraform/aws manages. If you're using terraform/aws,
# S3_PUBLIC_URL is that stack's cloudfront_domain_name output.

api_env_vars = {
  NODE_ENV      = "production"
  API_URI       = "https://plunk-api.saton.app"
  DASHBOARD_URI = "https://plunk-web.saton.app"
  LANDING_URI   = "https://www.useplunk.com"
  WIKI_URI      = "https://docs.useplunk.com"

  AWS_SES_REGION                    = "us-east-1" # (from AWS) e.g. us-east-1
  SES_CONFIGURATION_SET             = "plunk-configuration-set"
  SES_CONFIGURATION_SET_NO_TRACKING = "plunk-configuration-set-no-tracking"

  S3_ENDPOINT         = "https://s3.us-east-1.amazonaws.com"    # (from AWS) e.g. https://s3.us-east-1.amazonaws.com
  S3_REGION           = "us-east-1"                             # (from AWS)
  S3_BUCKET           = "bsaii-plunk-uploads-483528439217"      # (from AWS) terraform/aws's bucket_name output
  S3_PUBLIC_URL       = "https://d1wuh4t65cb8mi.cloudfront.net" # (from AWS) terraform/aws's cloudfront_domain_name output
  S3_FORCE_PATH_STYLE = "false"
}

web_env_vars = {
  API_URI       = "https://plunk-api.saton.app"
  DASHBOARD_URI = "https://plunk-web.saton.app"
  LANDING_URI   = "https://www.useplunk.com"
  WIKI_URI      = "https://docs.useplunk.com"
}

migrate_env_vars = {
  NODE_ENV = "production"
}

# Worker env vars are a SUBSET of the API's — S3_*, OAuth, Stripe price IDs,
# etc. are HTTP-only and never imported by the worker's code path (see
# docs/deploy-cloud-build.md's "Worker environment variables" section) — but
# AWS_SES_REGION is NOT optional here either: apps/api/src/jobs/worker.ts
# imports the same constants.ts, so the worker crashes at boot without it
# too.
worker_env_vars = {
  NODE_ENV      = "production"
  API_URI       = "https://plunk-api.saton.app"
  DASHBOARD_URI = "https://plunk-web.saton.app"
  LANDING_URI   = "https://www.useplunk.com"
  WIKI_URI      = "https://docs.useplunk.com"

  AWS_SES_REGION                    = "us-east-1" # (from AWS)
  SES_CONFIGURATION_SET             = "plunk-configuration-set"
  SES_CONFIGURATION_SET_NO_TRACKING = "plunk-configuration-set-no-tracking"
}

# --- Secret environment variables ---------------------------------------
# Map values are Secret Manager secret IDs (short names, not full resource
# paths) — create each one first, e.g.:
#   gcloud secrets create plunk-jwt-secret --replication-policy=automatic
#   echo -n "<value>" | gcloud secrets versions add plunk-jwt-secret --data-file=-
# iam.tf grants each runtime service account roles/secretmanager.secretAccessor
# scoped to exactly the secrets referenced below — nothing broader. See this
# directory's README for the full list of `gcloud secrets create` commands,
# including which values are (from AWS) and must be fetched from outside
# GCP Cloud Shell.

# STRIPE_SK / STRIPE_WEBHOOK_SECRET are OPTIONAL (constants.ts defaults both
# to "" and gates STRIPE_ENABLED on them being non-empty — billing features
# just stay off without them). Not wired up for this deployment, so they're
# deliberately absent below rather than pointing at throwaway secrets — add
# STRIPE_SK/STRIPE_WEBHOOK_SECRET back (with real Secret Manager IDs created
# first) if billing gets turned on later.
api_secret_env_vars = {
  JWT_SECRET                = "plunk-jwt-secret"
  DATABASE_URL              = "plunk-database-url"
  DIRECT_DATABASE_URL       = "plunk-direct-database-url"
  REDIS_URL                 = "plunk-redis-url"
  AWS_SES_ACCESS_KEY_ID     = "plunk-ses-access-key-id"     # (from AWS)
  AWS_SES_SECRET_ACCESS_KEY = "plunk-ses-secret-access-key" # (from AWS)
  S3_ACCESS_KEY_ID          = "plunk-s3-access-key-id"      # (from AWS)
  S3_ACCESS_KEY_SECRET      = "plunk-s3-access-key-secret"  # (from AWS)
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
  AWS_SES_ACCESS_KEY_ID     = "plunk-ses-access-key-id"     # (from AWS)
  AWS_SES_SECRET_ACCESS_KEY = "plunk-ses-secret-access-key" # (from AWS)
}
