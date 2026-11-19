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

variable "ingress_allowed_cidrs" {
  description = "IPv4 CIDRs allowed to reach the jumpbox HTTP and HTTPS proxy. Empty keeps public ingress closed."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.ingress_allowed_cidrs : try(cidrnetmask(cidr) != "0.0.0.0" && cidrhost(cidr, 0) == split("/", cidr)[0], false)])
    error_message = "Use specific IPv4 CIDRs, such as a workstation's public /32."
  }
}

variable "budget_alert_email" {
  description = "Email address for actual monthly account spending alerts"
  type        = string
}
