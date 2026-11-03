variable "aws_account_id" {
  type        = string
  description = "Target AWS account ID. Never committed: CI passes TF_VAR_aws_account_id; locally use the shell or a gitignored *.auto.tfvars."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be exactly 12 digits."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for every resource."
}

variable "prefix" {
  type        = string
  description = "Name prefix. Must equal the bootstrap prefix."
}

variable "env" {
  type        = string
  description = "Environment name. Must equal the directory name of this root (the parity guard checks it)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.env))
    error_message = "env must be 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4)."
  }
}

variable "memory_mb" {
  type        = number
  description = "Function memory in MB."
}

variable "timeout_s" {
  type        = number
  description = "Function timeout in seconds (at most 30, the HTTP API limit)."
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the function and API access log groups."
}

variable "secret_recovery_window_days" {
  type        = number
  description = "Secrets Manager recovery window; 0 deletes at once (ADR 0004, Q3)."
  default     = 0
}

variable "reserved_concurrency" {
  type        = number
  description = "Reserved concurrency of the function; null means no reservation (ADR 0012 L10, Finding 10)."
  default     = null
}

variable "api_throttle_rate_limit" {
  type        = number
  description = "Steady-state requests per second of the HTTP API stage (the cost ceiling, ADR 0012 L2)."
}

variable "api_throttle_burst_limit" {
  type        = number
  description = "Burst limit of the HTTP API stage."
}
