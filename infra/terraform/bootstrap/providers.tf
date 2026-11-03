provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  # Identical to envs/<env> (NFR-8): Project, Env, ManagedBy on every resource that supports tags.
  default_tags {
    tags = {
      Project   = local.tag_project
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
