# Partial configuration: the bucket name holds the account ID, so it is passed at init time with
#   terraform init -backend-config="bucket=<state bucket>"
# First apply uses a gitignored backend_override.tf with `backend "local" {}` (ADR 0002, B10).
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}
