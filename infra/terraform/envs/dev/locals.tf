locals {
  default_tags = {
    Project   = "ship-it-safely"
    Env       = var.env
    ManagedBy = "terraform"
  }

  # Unset means open, so demos from any network work (ADR 0007 Q3). The value is sensitive end to end.
  alb_ingress_cidrs = var.alb_ingress_cidrs_json == "" ? ["0.0.0.0/0"] : jsondecode(var.alb_ingress_cidrs_json)
}
