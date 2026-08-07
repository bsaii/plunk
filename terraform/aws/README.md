# Plunk — AWS Terraform

Creates the S3 uploads bucket, fronted by CloudFront as its public endpoint. The bucket itself
stays private; CloudFront gets read access via Origin Access Control (OAC), scoped to this one
distribution only.

## Out of scope: SES and SNS

Both are already configured manually today (SES for sending, SNS for the bounce/complaint
webhook at `POST /webhooks/sns`). Bringing them into Terraform is future work — not part of this
change.

## App-side change this Terraform depends on (already shipped in this PR)

`apps/api/src/services/S3Service.ts`'s `initializeBucket()` previously called
`PutBucketPolicyCommand` unconditionally on every boot to set a **public**-read bucket policy,
which would have silently reopened this bucket to direct public access and defeated the
CloudFront-only design here. That call is now guarded to only run for local Minio dev
(`S3_FORCE_PATH_STYLE=true`) and is skipped for real AWS S3, where this Terraform owns the
(CloudFront-scoped) bucket policy instead — see the diff in this PR.

Set `S3_PUBLIC_URL` in the app's env config to the `cloudfront_domain_name` output below instead
of a raw S3 endpoint.

## Usage

Bucket names are global across all of AWS — `bucket_name` defaults to `bsaii-plunk-uploads`;
override it if that's taken or you want a different name per environment.

State locking requires a DynamoDB table to already exist (see `versions.tf` for the exact
`aws dynamodb create-table` command and the Terraform-1.10+ native-locking alternative).

```bash
cd terraform/aws

terraform init \
  -backend-config="bucket=<your-terraform-state-bucket>" \
  -backend-config="key=plunk/aws/<environment>/terraform.tfstate" \
  -backend-config="region=<state-bucket-region>" \
  -backend-config="dynamodb_table=plunk-terraform-locks"

terraform validate
terraform plan -var="bucket_name=bsaii-plunk-uploads" -var="region=us-east-1"
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
