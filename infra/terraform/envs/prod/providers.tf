provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  # Identical to bootstrap (NFR-8). The apply role's EC2 conditions depend on these exact values (ADR 0002, B7, B14).
  default_tags {
    tags = local.default_tags
  }
}
