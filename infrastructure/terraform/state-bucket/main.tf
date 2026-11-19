terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.project_account_id]

  default_tags {
    tags = { Cost = "bootstrap" }
  }
}

# Bootstrap the trust separately from the lab: the role must exist before
# Terraform can assume it to manage the lab.
resource "aws_iam_role" "provisioner" {
  name = "kubernetes-hard-way-provisioner"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.trusted_principal_arn }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "kubernetes-hard-way-provisioner", ResourceType = "iam-role" }
}

resource "aws_s3_bucket" "state" {
  bucket = var.bucket_name
  tags   = { Name = var.bucket_name, ResourceType = "s3-state-bucket" }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

variable "aws_region" {
  description = "AWS region for the state bucket"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique name for the Terraform state bucket"
  type        = string
}

variable "trusted_principal_arn" {
  description = "IAM principal allowed to assume the provisioner role"
  type        = string
  default     = "arn:aws:iam::637423194439:user/nick-admin"
}

output "bucket_name" {
  description = "Bucket name to use when initializing the lab backend"
  value       = aws_s3_bucket.state.id
}

output "provisioner_role_arn" {
  description = "Role assumed by the lab AWS profile"
  value       = aws_iam_role.provisioner.arn
}
