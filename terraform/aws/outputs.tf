output "bucket_name" {
  description = "Name of the private S3 bucket storing uploads."
  value       = aws_s3_bucket.uploads.id
}

output "cloudfront_domain_name" {
  description = "Public CloudFront domain. Set S3_PUBLIC_URL to https://<this value> (or https://<cdn_domain> if a custom domain was configured)."
  value       = aws_cloudfront_distribution.uploads.domain_name
}
