# Plunk — AWS Terraform

Creates the S3 uploads bucket, fronted by CloudFront as its public endpoint. The bucket itself
stays private; CloudFront gets read access via Origin Access Control (OAC), scoped to this one
distribution only.

## Out of scope: SES and SNS

Both are already configured manually today (SES for sending, SNS for the bounce/complaint
webhook at `POST /webhooks/sns`). Bringing them into Terraform is future work — not part of this
change.

## Required app-side follow-up

`apps/api/src/services/S3Service.ts`'s `initializeBucket()` currently calls
`PutBucketPolicyCommand` unconditionally on every boot to set a **public**-read bucket policy.
Left as-is, this would silently reopen the bucket to direct public access and defeat the
CloudFront-only design here. That call needs to be guarded so it only runs for local Minio dev
(`S3_FORCE_PATH_STYLE=true`) and is skipped for real AWS S3, where this Terraform now owns the
(CloudFront-scoped) bucket policy.

Once this ships, update `S3_PUBLIC_URL` in the relevant env config to the `cloudfront_domain_name`
output instead of a raw S3 endpoint.

## Usage

```bash
cd terraform/aws

terraform init \
  -backend-config="bucket=<your-terraform-state-bucket>" \
  -backend-config="key=plunk/aws/<environment>/terraform.tfstate" \
  -backend-config="region=<state-bucket-region>"

terraform plan -var="bucket_name=uploads" -var="region=us-east-1"
terraform apply ...
```

## Resource inventory (for an AWS Pricing Calculator estimate)

| # | Resource | Type | Notes |
| --- | --- | --- | --- |
| 1 | `uploads` bucket | `aws_s3_bucket` | Storage (per GB) + request pricing |
| 2 | Versioning | `aws_s3_bucket_versioning` | Extra storage for prior object versions |
| 3 | SSE-S3 encryption | config only | No extra charge (SSE-S3 is free) |
| 4 | Public access block | config only | No charge |
| 5 | CloudFront distribution | `aws_cloudfront_distribution` | Data transfer out (per GB, varies by `cloudfront_price_class`) + request pricing — **primary cost driver** |
| 6 | Origin Access Control | `aws_cloudfront_origin_access_control` | No charge |
| 7 | Bucket policy (CloudFront-scoped) | `aws_s3_bucket_policy` | No charge |

`cloudfront_price_class` is the main lever to check against the pricing calculator:
`PriceClass_100` (default here) serves from North America + Europe edge locations only;
`PriceClass_All` adds Asia/South America/Australia edges at a higher rate.
