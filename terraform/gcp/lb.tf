# Global External Application Load Balancer in front of plunk-api and
# plunk-web, via serverless NEGs. This is the Google-recommended production
# path for custom domains on Cloud Run — direct `gcloud beta run
# domain-mappings create` is still Preview and not recommended for
# production. See https://cloud.google.com/run/docs/mapping-custom-domains
# and https://cloud.google.com/load-balancing/docs/https/setup-global-ext-https-serverless
#
#   DNS (manual, at your registrar) --A record--> load_balancer_ip output
#     --> this load balancer --host-based routing--> plunk-api / plunk-web
#
# DNS itself is NOT managed here (no Namecheap/DNS provider) — see the
# load_balancer_ip output and this directory's README for the A records to
# add once the IP below is reserved.

resource "google_compute_global_address" "plunk_lb_ip" {
  name         = "plunk-lb-ip"
  project      = var.project_id
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

resource "google_compute_managed_ssl_certificate" "plunk_cert" {
  name    = "plunk-cert"
  project = var.project_id

  managed {
    domains = [var.api_domain, var.web_domain]
  }
}

# --- Serverless NEGs: one per Cloud Run service --------------------------

resource "google_compute_region_network_endpoint_group" "api_neg" {
  name                  = "plunk-api-neg"
  project               = var.project_id
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.api.name
  }
}

resource "google_compute_region_network_endpoint_group" "web_neg" {
  name                  = "plunk-web-neg"
  project               = var.project_id
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.web.name
  }
}

# --- Backend services: one per NEG ----------------------------------------

resource "google_compute_backend_service" "api_backend" {
  name                  = "plunk-api-backend"
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.api_neg.id
  }
}

resource "google_compute_backend_service" "web_backend" {
  name                  = "plunk-web-backend"
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.web_neg.id
  }
}

# --- Host-based routing: api_domain -> api, web_domain -> web -------------

resource "google_compute_url_map" "plunk_lb" {
  name            = "plunk-lb"
  project         = var.project_id
  default_service = google_compute_backend_service.web_backend.id

  host_rule {
    hosts        = [var.api_domain]
    path_matcher = "api"
  }

  path_matcher {
    name            = "api"
    default_service = google_compute_backend_service.api_backend.id
  }

  host_rule {
    hosts        = [var.web_domain]
    path_matcher = "web"
  }

  path_matcher {
    name            = "web"
    default_service = google_compute_backend_service.web_backend.id
  }
}

resource "google_compute_target_https_proxy" "plunk_https_proxy" {
  name             = "plunk-https-proxy"
  project          = var.project_id
  url_map          = google_compute_url_map.plunk_lb.id
  ssl_certificates = [google_compute_managed_ssl_certificate.plunk_cert.id]
}

resource "google_compute_global_forwarding_rule" "plunk_https" {
  name                  = "plunk-https"
  project               = var.project_id
  ip_address            = google_compute_global_address.plunk_lb_ip.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.plunk_https_proxy.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# --- HTTP -> HTTPS redirect on port 80 -------------------------------------

resource "google_compute_url_map" "plunk_http_redirect" {
  name    = "plunk-http-redirect"
  project = var.project_id

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "plunk_http_proxy" {
  name    = "plunk-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.plunk_http_redirect.id
}

resource "google_compute_global_forwarding_rule" "plunk_http" {
  name                  = "plunk-http"
  project               = var.project_id
  ip_address            = google_compute_global_address.plunk_lb_ip.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.plunk_http_proxy.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
