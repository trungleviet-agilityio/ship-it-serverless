variable "aws_account_id" {
  type        = string
  description = "Target AWS account ID. Comes from the gitignored accounts/dev.tfvars or TF_VAR_aws_account_id."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be exactly 12 digits."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for every resource."
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like ap-southeast-1."
  }
}

variable "prefix" {
  type        = string
  description = "Name prefix for every resource."
  default     = "sls"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.prefix))
    error_message = "prefix must be 2 to 10 lowercase letters or digits, starting with a letter."
  }
}

variable "env" {
  type        = string
  description = "Environment name."
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.env))
    error_message = "env must be 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4)."
  }
}

variable "github_owner" {
  type        = string
  description = "GitHub user or organization that owns the repository."
  default     = "trungleviet-agilityio"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.github_owner))
    error_message = "github_owner may contain letters, digits and hyphens only."
  }
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name."
  default     = "ship-it-serverless"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo may contain letters, digits, dots, underscores and hyphens only."
  }
}

variable "github_owner_id" {
  type        = string
  description = "Immutable numeric ID of the GitHub owner (gh api repos/OWNER/REPO --jq .owner.id)."

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must contain digits only."
  }
}

variable "github_repo_id" {
  type        = string
  description = "Immutable numeric ID of the GitHub repository (gh api repos/OWNER/REPO --jq .id)."

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must contain digits only."
  }
}

variable "github_immutable_subject" {
  type        = bool
  description = "Use the OIDC sub format with immutable IDs. Set false only to fall back to name-based subjects."
  default     = true
}

variable "budget_email" {
  type        = string
  description = "Address that receives the budget alert."
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.budget_email))
    error_message = "budget_email must be a valid email address."
  }
}

variable "budget_limit_usd" {
  type        = number
  description = "Monthly cost budget in USD."
  default     = 20

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be positive."
  }
}

variable "budget_alert_threshold_percent" {
  type        = number
  description = "Percentage of the budget at which the actual-cost alert fires."
  default     = 80

  validation {
    condition     = var.budget_alert_threshold_percent > 0 && var.budget_alert_threshold_percent <= 100
    error_message = "budget_alert_threshold_percent must be between 1 and 100."
  }
}

variable "create_trail" {
  type        = bool
  description = "Create the CloudTrail trail and its bucket. Set false when the account already has a trail, so management events are not paid for twice. The alert rule is created either way."
  default     = true
}

variable "promotion_source_account_id" {
  type        = string
  description = "Account that builds the images this environment promotes (ADR 0008 P9). Null for the build environment (dev). Set in a promoted environment (prod): its deploy role may then pull from the source repository, and it trusts app-promote.yml instead of app-deploy.yml (P7)."
  default     = null

  validation {
    condition     = var.promotion_source_account_id == null || can(regex("^[0-9]{12}$", var.promotion_source_account_id))
    error_message = "promotion_source_account_id must be null or exactly 12 digits."
  }
}

variable "promotion_source_env" {
  type        = string
  description = "Environment name of the promotion source; names its repository <prefix>-<env>-app."
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.promotion_source_env))
    error_message = "promotion_source_env must be 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4)."
  }
}

variable "promotion_target_account_id" {
  type        = string
  description = "Account of the environment that promotes images from this one (ADR 0008 P9, ADR 0012 L4), e.g. the prod account in dev. Null: the repository policy has no PromotionPull statement. Sensitive, so it never prints in a plan."
  default     = null
  sensitive   = true

  validation {
    condition     = var.promotion_target_account_id == null || can(regex("^[0-9]{12}$", var.promotion_target_account_id))
    error_message = "promotion_target_account_id must be null or exactly 12 digits."
  }
}

variable "promotion_target_env" {
  type        = string
  description = "Environment name of the promotion target; PromotionPull names its deploy role <prefix>-<env>-gha-deploy. Used only when promotion_target_account_id is set."
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.promotion_target_env))
    error_message = "promotion_target_env must be 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4)."
  }
}
