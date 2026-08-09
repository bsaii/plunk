# Production values for the AWS uploads stack (S3 + CloudFront).
#
# bucket_name is intentionally account-suffixed and MUST match the bucket
# that already exists in production — S3 bucket names are globally unique,
# and the plain "bsaii-plunk-uploads" name in variables.tf's default is
# already taken. Passing a different bucket_name (or omitting this file)
# makes Terraform plan a replacement of the S3 bucket and OAC, which
# `prevent_destroy` blocks but which you never want to plan in the first
# place. Contains no credentials — safe to commit.
#
# cloudfront_price_class and cloudfront_web_acl_arn are pinned to the
# console-observed state of the production distribution so `terraform plan`
# stops proposing to revert them. Before relying on this, confirm directly
# against the AWS account (e.g. `aws cloudfront get-distribution-config` /
# `aws wafv2 get-web-acl`) that this web ACL exists, belongs to this
# account, and is genuinely associated with the production distribution —
# this was not independently verified when this file was written.
bucket_name            = "bsaii-plunk-uploads-483528439217"
region                 = "us-east-1"
environment            = "production"
cloudfront_price_class = "PriceClass_All"
cloudfront_web_acl_arn = "arn:aws:wafv2:us-east-1:483528439217:global/webacl/CreatedByCloudFront-e2444887/40ed8f03-9dbd-43ea-9787-59e656e884aa"
