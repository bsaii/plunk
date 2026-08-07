terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Bucket/key/region/lock-table are supplied per environment, not hardcoded.
  # dynamodb_table enables state locking (a concurrent `apply` waits instead
  # of racing and corrupting state) — the table must already exist, e.g.:
  #   aws dynamodb create-table --table-name plunk-terraform-locks \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST
  #   terraform init \
  #     -backend-config="bucket=<your-terraform-state-bucket>" \
  #     -backend-config="key=plunk/aws/<environment>/terraform.tfstate" \
  #     -backend-config="region=<state-bucket-region>" \
  #     -backend-config="dynamodb_table=plunk-terraform-locks"
  # On Terraform >= 1.10 you can instead skip the DynamoDB table entirely and
  # pass -backend-config="use_lockfile=true" for native S3-based locking.
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
