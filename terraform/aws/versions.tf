terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Bucket/key/region are supplied per environment, not hardcoded:
  #   terraform init \
  #     -backend-config="bucket=<your-terraform-state-bucket>" \
  #     -backend-config="key=plunk/aws/<environment>/terraform.tfstate" \
  #     -backend-config="region=<state-bucket-region>"
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
