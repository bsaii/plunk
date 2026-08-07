# Runtime IAM identity Plunk uses to upload objects to the uploads bucket.
# Kept separate from the SES IAM user (managed outside Terraform today) so
# that compromised storage credentials can't send email or touch SES
# identities, and vice versa.
#
# Deliberately does not grant s3:CreateBucket or s3:PutBucketPolicy —
# Terraform owns bucket creation and the CloudFront-scoped bucket policy
# (see s3.tf / cdn.tf). s3:ListBucket covers HeadBucket calls, so a
# dedicated permission for that isn't needed either.
#
# The access key itself is intentionally NOT created here — aws_iam_access_key
# would store the secret access key in Terraform state. Create it out of band
# with `aws iam create-access-key` and put it straight into secrets storage
# (see README.md).
data "aws_iam_policy_document" "s3_runtime" {
  statement {
    sid    = "ReadUploadsBucketMetadata"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [
      aws_s3_bucket.uploads.arn,
    ]
  }

  statement {
    sid    = "UploadObjects"
    effect = "Allow"

    actions = [
      "s3:PutObject",
    ]

    resources = [
      "${aws_s3_bucket.uploads.arn}/*",
    ]
  }
}

resource "aws_iam_user" "s3_runtime" {
  name = "plunk-s3-${var.environment}"
  path = "/plunk/"

  tags = {
    environment = var.environment
    component   = "s3-runtime"
  }
}

resource "aws_iam_policy" "s3_runtime" {
  name        = "plunk-s3-${var.environment}"
  description = "Allows Plunk to upload objects to its production uploads bucket"
  policy      = data.aws_iam_policy_document.s3_runtime.json

  tags = {
    environment = var.environment
    component   = "s3-runtime"
  }
}

resource "aws_iam_user_policy_attachment" "s3_runtime" {
  user       = aws_iam_user.s3_runtime.name
  policy_arn = aws_iam_policy.s3_runtime.arn
}
