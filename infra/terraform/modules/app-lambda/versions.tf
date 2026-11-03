terraform {
  # use_lockfile is GA from 1.11 (ADR 0002, B1).
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}
