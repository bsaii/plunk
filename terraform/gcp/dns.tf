# Cloudflare sits in front of both services as a proxy (orange-clouded DNS)
# instead of a GCP load balancer — see this directory's README for the
# reasoning. Cloud Run Domain Mappings are what let Cloud Run itself
# recognize and terminate TLS for api_domain/web_domain: Google verifies you
# own the domain, issues a managed certificate for it, and routes requests
# for that Host header to the named service. Cloudflare's proxy then just
# needs a CNAME to ghs.googlehosted.com (or the A/AAAA records Google
# assigns for an apex domain) — see the `*_domain_mapping_records` outputs
# for the exact records to add.
#
# Requires the domain to already be verified for this GCP project's identity
# in Search Console (https://support.google.com/webmasters/answer/9008080)
# before `apply` — Google won't issue a certificate for a domain it can't
# confirm you own. Domain Mappings are also only available in a subset of
# regions (var.region's default, us-central1, is one of them) — check
# https://cloud.google.com/run/docs/mapping-custom-domains#run before
# picking a different one.

resource "google_cloud_run_domain_mapping" "api" {
  name     = var.api_domain
  location = var.region
  project  = var.project_id

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloud_run_v2_service.api.name
  }
}

resource "google_cloud_run_domain_mapping" "web" {
  name     = var.web_domain
  location = var.region
  project  = var.project_id

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloud_run_v2_service.web.name
  }
}
