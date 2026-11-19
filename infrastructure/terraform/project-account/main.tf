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
  region              = "us-east-1"
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = { Cost = "bootstrap" }
  }
}

variable "management_account_id" {
  description = "AWS Organizations management account ID"
  type        = string
}

variable "project_account_email" {
  description = "Unused email address you control for the new member account"
  type        = string
}

resource "aws_organizations_account" "project" {
  name              = "Kubernetes The Hard Way"
  email             = var.project_account_email
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = false
  tags              = { Name = "kubernetes-hard-way", ResourceType = "aws-account" }

  lifecycle {
    prevent_destroy = true
  }
}

output "project_account_id" {
  value = aws_organizations_account.project.id
}
