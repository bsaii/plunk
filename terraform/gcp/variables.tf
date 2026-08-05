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
