variable "bucket_name" {
  description = "S3 bucket name for uploaded attachments/images. Matches S3_BUCKET in apps/api/.env.example (default 'uploads')."
  type        = string
  default     = "uploads"
}

variable "region" {
  description = "AWS region for the bucket. Must match S3_REGION in the API's env config."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment tag applied to every resource."
  type        = string
  default     = "production"
}

variable "cdn_domain" {
  description = "Optional custom CloudFront domain (e.g. uploads.example.com). Requires cdn_acm_certificate_arn. Leave null to use CloudFront's own *.cloudfront.net domain, which needs no ACM certificate and is the default for this change."
  type        = string
  default     = null
}

variable "cdn_acm_certificate_arn" {
  description = "ACM certificate ARN, must be in us-east-1 (CloudFront requirement) regardless of `region`. Required only when cdn_domain is set."
  type        = string
  default     = null
}

variable "cloudfront_price_class" {
  description = "CloudFront price class — the primary cost lever for this distribution. PriceClass_100 restricts to NA/EU edge locations (cheapest); PriceClass_All covers every edge location (priciest, best global latency)."
  type        = string
  default     = "PriceClass_100"
}
