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

## S3 IAM user (runtime credentials)

`iam.tf` creates the IAM user, least-privilege policy, and policy attachment Plunk uses at
runtime to upload objects (`s3:PutObject`) and read bucket metadata (`s3:ListBucket`,
`s3:GetBucketLocation` — `HeadBucket` works through `s3:ListBucket`). It's a separate IAM user
from the existing SES one (managed outside Terraform): compromised storage credentials shouldn't
be able to send email or touch SES identities, and compromised SES credentials shouldn't be able
to read/write uploaded files.

The policy deliberately excludes `s3:CreateBucket` and `s3:PutBucketPolicy` — Terraform owns
those.

The access key is **not** created by Terraform (`aws_iam_access_key` would put the secret access
key in state). Create it manually after applying:

```bash
export PLUNK_S3_IAM_USER="$(terraform output -raw s3_iam_user_name)"

aws iam list-access-keys --user-name "$PLUNK_S3_IAM_USER" \
  --query 'AccessKeyMetadata[].{AccessKeyId:AccessKeyId,Status:Status,Created:CreateDate}' \
  --output table

# Only if the user has no existing key:
aws iam create-access-key --user-name "$PLUNK_S3_IAM_USER" \
  --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' \
  --output json
```

The secret access key is shown only once — copy both values straight into your secrets manager
as `S3_ACCESS_KEY_ID` / `S3_ACCESS_KEY_SECRET`. Do not save them in the repo, `.tfvars`,
Terraform outputs, or shell history.

## Usage

Bucket names are global across all of AWS — `bucket_name` defaults to `bsaii-plunk-uploads` in
`variables.tf`, but that name is already taken, so it does **not** match the real production
bucket. Production always plans against the committed `production.tfvars`, which pins the actual
bucket name (`bsaii-plunk-uploads-483528439217`) alongside `region`, `environment`, and
`cloudfront_price_class`. Never `terraform plan`/`apply` against production with ad-hoc `-var`
flags or with no var file — either falls back to the mismatched default and plans a destructive
replacement of the S3 bucket and OAC (which `prevent_destroy` will then block, but you don't want
to get that far). `production.tfvars` contains no credentials, so it's safe to commit.

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
terraform plan -var-file=production.tfvars -out=production.tfplan
terraform show -no-color production.tfplan   # confirm no bucket/OAC replacement before applying
terraform apply production.tfplan
```

For a new/non-production environment with its own bucket name, either add a matching
`<environment>.tfvars` or pass `-var` flags explicitly — just don't do that against production.

### WAF association and price class (`production.tfvars`)

Production's `cloudfront_price_class` is `PriceClass_All` and `cloudfront_web_acl_arn` points at
an existing WAFv2 web ACL (`CreatedByCloudFront-e2444887`), matching state that was previously
changed outside Terraform. **This was not independently verified against the AWS account** by
whoever last edited `production.tfvars` — before trusting it, confirm directly:

```bash
aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 \
  --name CreatedByCloudFront-e2444887 --id 40ed8f03-9dbd-43ea-9787-59e656e884aa
aws cloudfront get-distribution-config --id <distribution-id>   # check WebACLId and PriceClass
```

If the ACL doesn't exist, isn't associated with the `uploads` distribution, or you don't recognize
it, do not run `terraform apply` with these values — treat it as a signal to investigate the AWS
account for unauthorized changes before proceeding.

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
| 8 | S3 runtime IAM user | `aws_iam_user` | No charge |
| 9 | S3 runtime IAM policy | `aws_iam_policy` | No charge |
| 10 | S3 runtime IAM policy attachment | `aws_iam_user_policy_attachment` | No charge |

`cloudfront_price_class` is the main lever to check against the pricing calculator:
`PriceClass_100` (default here) serves from North America + Europe edge locations only;
`PriceClass_All` adds Asia/South America/Australia edges at a higher rate.
