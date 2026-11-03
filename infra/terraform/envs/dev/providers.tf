provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  # Identical to bootstrap (NFR-8): Project, Env, ManagedBy on every resource that supports tags.
  default_tags {
    tags = local.default_tags
  }
}
