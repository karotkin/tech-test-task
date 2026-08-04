# -----------------------------------------------------------------------------
# Bootstrap: creates the S3 bucket + DynamoDB lock table used as the remote
# backend for environments/dev. State for this config stays local on purpose
# (chicken-and-egg: can't store backend-bootstrap state in the backend it's
# creating). Apply this once before `terraform init` in environments/dev.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name" {
  type    = string
  default = "test-opsfleet-dev-tfstate"
}

variable "lock_table_name" {
  type    = string
  default = "test-opsfleet-dev-tfstate-lock"
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.bucket_name

  # Test resource, torn down together with the rest — no accidental-delete guard.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "dynamodb_table" {
  value = aws_dynamodb_table.lock.name
}

output "region" {
  value = var.aws_region
}
