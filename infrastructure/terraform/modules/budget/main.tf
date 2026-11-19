terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "name" {
  description = "Name of the monthly account cost budget"
  type        = string
}

variable "monthly_amount" {
  description = "Monthly budget limit in US dollars"
  type        = number
  validation {
    condition     = var.monthly_amount > 0
    error_message = "The monthly budget must be greater than zero."
  }
}

variable "alert_email" {
  description = "Email address receiving budget alerts"
  type        = string
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "Provide a valid budget alert email address."
  }
}

variable "alert_thresholds" {
  description = "Actual spend notification thresholds as percentages of the budget"
  type        = set(number)
  default     = [80, 90]
  validation {
    condition     = length(var.alert_thresholds) > 0 && length(var.alert_thresholds) <= 5 && alltrue([for threshold in var.alert_thresholds : threshold > 0 && threshold <= 1000])
    error_message = "Provide one to five thresholds between 0 and 1000 percent."
  }
}

resource "aws_budgets_budget" "this" {
  name         = var.name
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_amount)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.alert_thresholds
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
