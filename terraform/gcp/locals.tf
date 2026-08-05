# Two labels only, per team decision:
#   - environment: separates cost/queries per environment if this project
#     ever hosts more than one (production, staging, ...).
#   - component: added per-resource below (api/web/migrate/lb), breaks down
#     Cloud Billing cost reports and `gcloud ... --filter=labels.component=x`
#     queries per piece of infrastructure instead of one lump sum.
locals {
  common_labels = {
    environment = var.environment
  }
}
