# CloudFront is the public endpoint for uploaded files — the bucket itself
# stays private (see s3.tf). Origin Access Control (OAC) is the current
# AWS-recommended way to grant CloudFront read access, replacing the older
# Origin Access Identity (OAI) mechanism.
resource "aws_cloudfront_origin_access_control" "uploads" {
  name                              = "${var.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed policy — avoids the legacy forwarded_values block, which the
# CloudFront Free flat-rate plan does not support.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "uploads" {
  enabled     = true
  comment     = "Plunk uploads (public read endpoint for ${var.bucket_name})"
  price_class = var.cloudfront_price_class

  aliases = var.cdn_domain != null ? [var.cdn_domain] : []

  origin {
    domain_name              = aws_s3_bucket.uploads.bucket_regional_domain_name
    origin_id                = "s3-${var.bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.uploads.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${var.bucket_name}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Defaults to CloudFront's own certificate/domain (no ACM cert needed).
  # Set cdn_domain + cdn_acm_certificate_arn to use a custom hostname instead.
  viewer_certificate {
    cloudfront_default_certificate = var.cdn_domain == null ? true : null
    acm_certificate_arn            = var.cdn_domain != null ? var.cdn_acm_certificate_arn : null
    ssl_support_method             = var.cdn_domain != null ? "sni-only" : null
    minimum_protocol_version       = var.cdn_domain != null ? "TLSv1.2_2021" : null
  }

  tags = {
    environment = var.environment
    component   = "cdn"
  }
}

# Scoped to this specific distribution only (via the SourceArn condition) —
# not a public Principal:"*" policy.
data "aws_iam_policy_document" "uploads_cloudfront_read" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.uploads.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "uploads_cloudfront_read" {
  bucket = aws_s3_bucket.uploads.id
  policy = data.aws_iam_policy_document.uploads_cloudfront_read.json
}
