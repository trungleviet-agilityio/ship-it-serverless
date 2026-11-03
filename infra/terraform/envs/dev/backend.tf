# Partial configuration: the bucket name holds the account ID, so it is passed at init time with
#   terraform init -backend-config="bucket=<state bucket>"
# CI derives it as sis-<env>-tfstate-<account>-<region>-an (ADR 0004, E22). Only the key line differs per environment.
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}
