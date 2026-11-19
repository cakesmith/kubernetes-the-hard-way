module "budget" {
  source = "./modules/budget"

  name           = "kubernetes-hard-way-monthly"
  monthly_amount = 50
  alert_email    = var.budget_alert_email
}
