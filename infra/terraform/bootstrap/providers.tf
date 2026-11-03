provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  # The apply role's EC2 conditions depend on these exact values (B7, B14).
  default_tags {
    tags = {
      Project   = "ship-it-safely"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
