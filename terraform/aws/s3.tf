# Private uploads bucket. Public read access is granted ONLY to CloudFront
# (via Origin Access Control, see cdn.tf) — there is no public bucket policy
# here. This replaces the app's previous runtime behavior of setting a
# Principal:"*" public-read bucket policy on every boot; see the required
# S3Service.ts follow-up noted in this directory's README.
resource "aws_s3_bucket" "uploads" {
  bucket = var.bucket_name

  tags = {
    environment = var.environment
    component   = "s3"
  }

  # This bucket holds customer-uploaded attachments/images — an accidental
  # `terraform destroy` (or a bucket_name change forcing replacement) must
  # not silently delete it. Remove this only if you deliberately intend to
  # destroy the bucket, e.g. tearing down a throwaway environment.
  lifecycle {
    prevent_destroy = true
  }
}

# Protects against accidental overwrite/delete of uploaded attachments.
resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Fully private — CloudFront's Origin Access Control is the only path in.
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
