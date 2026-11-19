variable "aws_region" {
  description = "AWS region in which to create the lab; must match the bootstrap lab_region"
  type        = string
  default     = "us-east-1"
}

variable "project_account_id" {
  description = "AWS Organizations member account ID for this lab"
  type        = string
}

variable "ssh_public_key" {
  description = "OpenSSH public key for the Debian admin user; keep its private key locally"
  type        = string
}

variable "availability_zone_id" {
  description = "Optional physical AZ ID to align with a future peer VPC"
  type        = string
  default     = null
}
