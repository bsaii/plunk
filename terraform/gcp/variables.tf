variable "project_id" {
  description = "GCP project ID that hosts all Plunk infrastructure."
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Run services, the migrate job, and the load balancer's regional resources (serverless NEGs)."
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Deployment environment label applied to every resource (e.g. production, staging)."
  type        = string
  default     = "production"
}

# --- Artifact Registry ------------------------------------------------------

variable "artifact_registry_repository_id" {
  description = "Artifact Registry Docker repository name. Must match cloudbuild.yaml's _AR_REPO substitution."
  type        = string
  default     = "plunk"
}

# --- Cloud Build -------------------------------------------------------------
# The build service account itself is NOT managed by this Terraform — Google
# recommends a user-managed build service account over the legacy default
# PROJECT_NUMBER@cloudbuild.gserviceaccount.com (see docs/deploy-cloud-build.md),
# and creating it here would conflict with the one already created out of band
# for the GCP project this Terraform targets. iam.tf only ever grants IAM
# roles to the email below — never creates or deletes the account.

variable "cloud_build_service_account_id" {
  description = "Account ID (the part before @) of the user-managed Cloud Build service account that runs cloudbuild.yaml. Must already exist — see docs/deploy-cloud-build.md."
  type        = string
  default     = "plunk-cloud-build"
}

# --- Images -------------------------------------------------------------
# cloudbuild.yaml rolls these forward on every merge via `gcloud run deploy` /
# `gcloud run jobs update`. Terraform's lifecycle.ignore_changes on the
# container image field (see api.tf/web.tf/migrate.tf) means these defaults
# only matter for the very first `terraform apply`, before Cloud Build has
# ever run — pick any pullable placeholder image.

variable "api_image" {
  description = "Container image for plunk-api. Only used on first apply; Cloud Build owns the image afterwards."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "web_image" {
  description = "Container image for plunk-web. Only used on first apply; Cloud Build owns the image afterwards."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "migrate_image" {
  description = "Container image for the plunk-migrate job (same image as the API). Only used on first apply."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "worker_image" {
  description = "Container image for the plunk-worker Cloud Run Worker Pool (worker-runner target, same image family as the API). Only used on first apply; cloudbuild.yaml's update-worker-pool step owns the image afterwards."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

# --- Domains --------------------------------------------------------------

variable "api_domain" {
  description = "Public hostname routed to plunk-api by the load balancer, e.g. plunk-api.example.com."
  type        = string
}

variable "web_domain" {
  description = "Public hostname routed to plunk-web by the load balancer, e.g. plunk-app.example.com."
  type        = string
}

# --- Environment variables -------------------------------------------------
# Non-secret values go in the plain maps below. Secret values (JWT_SECRET,
# DATABASE_URL, AWS_SES_SECRET_ACCESS_KEY, etc.) go in the *_secret_env_vars
# maps as { ENV_VAR_NAME = "secret-manager-secret-id" } — Terraform only ever
# references the secret's name/version (always "latest"), never its value, so
# no secret material enters .tf/.tfvars files or Terraform state. The
# referenced secrets must already exist in Secret Manager; creating/rotating
# them is out of scope here.

variable "api_env_vars" {
  description = "Non-secret environment variables for plunk-api (e.g. API_URI, DASHBOARD_URI, LANDING_URI, WIKI_URI, NODE_ENV)."
  type        = map(string)
  default     = {}
}

variable "web_env_vars" {
  description = "Non-secret environment variables for plunk-web."
  type        = map(string)
  default     = {}
}

variable "migrate_env_vars" {
  description = "Non-secret environment variables for the plunk-migrate job."
  type        = map(string)
  default     = {}
}

variable "api_secret_env_vars" {
  description = "Map of env var name to Secret Manager secret ID for plunk-api's secret values."
  type        = map(string)
  default     = {}
}

variable "web_secret_env_vars" {
  description = "Map of env var name to Secret Manager secret ID for plunk-web's secret values."
  type        = map(string)
  default     = {}
}

variable "migrate_secret_env_vars" {
  description = "Map of env var name to Secret Manager secret ID for plunk-migrate's secret values."
  type        = map(string)
  default     = {}
}

variable "worker_env_vars" {
  description = "Non-secret environment variables for the plunk-worker Worker Pool. The worker only needs a SUBSET of the API's vars — see docs/deploy-cloud-build.md's \"Worker environment variables\" section."
  type        = map(string)
  default     = {}
}

variable "worker_secret_env_vars" {
  description = "Map of env var name to Secret Manager secret ID for plunk-worker's secret values."
  type        = map(string)
  default     = {}
}

# --- Explicit compute sizing -------------------------------------------------
# Defaults match docs/deploy-cloud-run.md / docs/deploy-cloud-build.md's
# bootstrap commands. Override per environment in a *.tfvars file (see
# production.tfvars) rather than relying on Cloud Run's own defaults, so
# `terraform plan` is the source of truth for what's actually provisioned.

variable "api_cpu" {
  description = "vCPU allocation for plunk-api."
  type        = string
  default     = "1"
}

variable "api_memory" {
  description = "Memory allocation for plunk-api."
  type        = string
  default     = "512Mi"
}

variable "api_max_instance_count" {
  description = "Maximum autoscaled instance count for plunk-api."
  type        = number
  default     = 10
}

variable "web_cpu" {
  description = "vCPU allocation for plunk-web."
  type        = string
  default     = "1"
}

variable "web_memory" {
  description = "Memory allocation for plunk-web."
  type        = string
  default     = "512Mi"
}

variable "web_max_instance_count" {
  description = "Maximum autoscaled instance count for plunk-web."
  type        = number
  default     = 10
}

variable "migrate_cpu" {
  description = "vCPU allocation for the plunk-migrate job."
  type        = string
  default     = "1"
}

variable "migrate_memory" {
  description = "Memory allocation for the plunk-migrate job."
  type        = string
  default     = "512Mi"
}

variable "worker_cpu" {
  description = "vCPU allocation for each plunk-worker instance."
  type        = string
  default     = "1"
}

variable "worker_memory" {
  description = "Memory allocation for each plunk-worker instance."
  type        = string
  default     = "512Mi"
}

variable "worker_instance_count" {
  description = "Fixed instance count for plunk-worker (manual scaling — see worker.tf's scaling block). Kept at 1 by default — unlike plunk-web, the BullMQ worker has no HTTP entrypoint to cold-start on, so scaling to zero means queued jobs simply wait until an instance is scaled back up. Raise this by hand if queue throughput needs more than one instance; Worker Pools do not autoscale on load the way a Cloud Run service does."
  type        = number
  default     = 1
}
