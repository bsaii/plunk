# Production values for the AWS uploads stack (S3 + CloudFront).
#
# bucket_name is intentionally account-suffixed and MUST match the bucket
# that already exists in production — S3 bucket names are globally unique,
# and the plain "bsaii-plunk-uploads" name in variables.tf's default is
# already taken. Passing a different bucket_name (or omitting this file)
# makes Terraform plan a replacement of the S3 bucket and OAC, which
# `prevent_destroy` blocks but which you never want to plan in the first
# place. Contains no credentials — safe to commit.
bucket_name             = "bsaii-plunk-uploads-483528439217"
region                  = "us-east-1"
environment             = "production"
cloudfront_price_class  = "PriceClass_100"
