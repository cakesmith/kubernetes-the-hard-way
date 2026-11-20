variable "project_account_id" {
  description = "AWS Organizations member account ID for this project"
  type        = string
}

variable "lab_region" {
  description = "Region in which the project roles can manage lab resources"
  type        = string
  default     = "us-east-1"
}

data "aws_partition" "current" {}

locals {
  partition     = data.aws_partition.current.partition
  state_key     = "kubernetes-hard-way/terraform.tfstate"
  state_objects = [for suffix in ["", ".tflock"] : "${aws_s3_bucket.state.arn}/${local.state_key}${suffix}"]
  lab_ec2_arn   = "arn:${local.partition}:ec2:${var.lab_region}:${var.project_account_id}"
  lab_ssm_arn   = "arn:${local.partition}:ssm:${var.lab_region}:${var.project_account_id}"
  access_tags   = { Name = "kubernetes-hard-way-instance-access", ResourceType = "iam-role" }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ProtectStateObjects"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = "${aws_s3_bucket.state.arn}/*"
      Condition = {
        ArnNotEquals = { "aws:PrincipalArn" = aws_iam_role.provisioner.arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "provisioner" {
  name = "kubernetes-hard-way"
  role = aws_iam_role.provisioner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = local.state_objects
      },
      {
        Effect   = "Allow"
        Action   = "s3:DeleteObject"
        Resource = local.state_objects[1]
      },
      {
        Sid    = "ManageLabInDedicatedAccount"
        Effect = "Allow"
        Action = [
          "ec2:Describe*", "ec2:GetSecurityGroupsForVpc",
          "ec2:CreateVpc", "ec2:ModifyVpcAttribute", "ec2:DeleteVpc",
          "ec2:CreateSubnet", "ec2:ModifySubnetAttribute", "ec2:DeleteSubnet",
          "ec2:CreateInternetGateway", "ec2:AttachInternetGateway",
          "ec2:DetachInternetGateway", "ec2:DeleteInternetGateway",
          "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:AssociateRouteTable",
          "ec2:DisassociateRouteTable", "ec2:ReplaceRouteTableAssociation",
          "ec2:CreateRoute", "ec2:ReplaceRoute", "ec2:DeleteRoute",
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
          "ec2:ImportKeyPair", "ec2:DeleteKeyPair",
          "ec2:RunInstances", "ec2:ModifyInstanceAttribute",
          "ec2:ModifyInstanceMetadataOptions", "ec2:ModifyInstanceCreditSpecification",
          "ec2:ModifyNetworkInterfaceAttribute", "ec2:ModifyVolume",
          "ec2:CreateTags", "ec2:DeleteTags",
          "ec2:AssociateIamInstanceProfile", "ec2:DisassociateIamInstanceProfile",
          "ec2:ReplaceIamInstanceProfileAssociation"
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.lab_region } }
      },
      {
        Sid      = "TerminateLabInstances"
        Effect   = "Allow"
        Action   = "ec2:TerminateInstances"
        Resource = "${local.lab_ec2_arn}:instance/*"
        Condition = {
          StringEquals = { "ec2:ResourceTag/ManagedBy" = "kubernetes-hard-way" }
        }
      },
      {
        Sid      = "ManageAccountBudget"
        Effect   = "Allow"
        Action   = ["budgets:ViewBudget", "budgets:ModifyBudget", "budgets:TagResource", "budgets:UntagResource", "budgets:ListTagsForResource", "aws-portal:ViewBilling", "aws-portal:ModifyBilling"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.jumpbox.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      }
    ]
  })
}

resource "aws_iam_role" "jumpbox" {
  name = "kubernetes-hard-way-jumpbox"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "kubernetes-hard-way-jumpbox", ResourceType = "iam-role" }
}

resource "aws_iam_role_policy" "jumpbox" {
  name = "session-manager-agent"
  role = aws_iam_role.jumpbox.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "jumpbox" {
  name = aws_iam_role.jumpbox.name
  role = aws_iam_role.jumpbox.name
  tags = { Name = "kubernetes-hard-way-jumpbox", ResourceType = "iam-instance-profile" }
}

resource "aws_iam_role" "instance_access" {
  name               = "kubernetes-hard-way-instance-access"
  assume_role_policy = aws_iam_role.provisioner.assume_role_policy
  tags               = local.access_tags
}

resource "aws_iam_role_policy" "instance_power" {
  name = "lab-instance-power"
  role = aws_iam_role.instance_access.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ReadInstanceStatus"
        Effect    = "Allow"
        Action    = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.lab_region } }
      },
      {
        Sid      = "ManageLabInstancePower"
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "${local.lab_ec2_arn}:instance/*"
        Condition = {
          StringEquals = { "ec2:ResourceTag/ManagedBy" = "kubernetes-hard-way" }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "instance_access" {
  name = "jumpbox-ssh"
  role = aws_iam_role.instance_access.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "${local.lab_ec2_arn}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Name"      = "jumpbox"
            "ssm:resourceTag/ManagedBy" = "kubernetes-hard-way"
          }
          BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:${local.partition}:ssm:${var.lab_region}::document/AWS-StartSSHSession"
      },
      {
        Effect   = "Allow"
        Action   = ["ssmmessages:OpenDataChannel", "ssm:TerminateSession"]
        Resource = "${local.lab_ssm_arn}:session/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/aws:ssmmessages:session-id" = "$${aws:userid}"
          }
        }
      }
    ]
  })
}

output "instance_access_role_arn" {
  value = aws_iam_role.instance_access.arn
}

output "backend_config" {
  description = "Write to a local .s3.tfbackend file for terraform init"
  value       = <<-EOT
    bucket              = "${aws_s3_bucket.state.id}"
    region              = "${var.aws_region}"
    allowed_account_ids = ["${var.project_account_id}"]
  EOT
}
