variable "prefix" {
  type        = string
  description = "Name prefix for every resource. Must equal the bootstrap prefix (name contract, ADR 0002)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.prefix))
    error_message = "prefix must be 2 to 10 lowercase letters or digits, starting with a letter."
  }
}

variable "env" {
  type        = string
  description = "Environment name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.env))
    error_message = "env must be 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4)."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region of the stack. Used for the ECR repository URL."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like ap-southeast-1."
  }
}

variable "memory_mb" {
  type        = number
  description = "Function memory in MB (ADR 0012 L1: 512). CPU scales with it; so does the GB-second price."
  default     = 512

  validation {
    condition     = var.memory_mb >= 128 && var.memory_mb <= 2048 && floor(var.memory_mb) == var.memory_mb
    error_message = "memory_mb must be a whole number between 128 and 2048 (lab cost guard; Lambda allows up to 10240)."
  }
}

variable "timeout_s" {
  type        = number
  description = "Function timeout in seconds (ADR 0012 L1: 10). At most 30, the HTTP API integration limit."
  default     = 10

  validation {
    condition     = var.timeout_s >= 1 && var.timeout_s <= 30 && floor(var.timeout_s) == var.timeout_s
    error_message = "timeout_s must be a whole number between 1 and 30 (the HTTP API gives up after about 30 s)."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the function and API access log groups."
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30], var.log_retention_days)
    error_message = "log_retention_days must be one of 1, 3, 5, 7, 14, 30."
  }
}

variable "secret_recovery_window_days" {
  type        = number
  description = "Secrets Manager recovery window. 0 deletes at once, so a torn-down stack can be re-created (ADR 0004, Q3)."
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 or between 7 and 30."
  }
}

variable "reserved_concurrency" {
  type        = number
  description = "Reserved concurrency of the function (ADR 0012 L10). Null: no reservation. Lambda refuses a reservation that leaves less than 100 unreserved, so accounts with a low quota must keep null (Finding 10)."
  default     = null

  validation {
    condition     = var.reserved_concurrency == null || try(var.reserved_concurrency >= 1 && var.reserved_concurrency <= 100 && floor(var.reserved_concurrency) == var.reserved_concurrency, false)
    error_message = "reserved_concurrency must be null or a whole number between 1 and 100 (0 would disable the function)."
  }
}

variable "api_throttle_rate_limit" {
  type        = number
  description = "Steady-state requests per second the HTTP API stage accepts (ADR 0012 L2, R1: the cost ceiling)."
  default     = 5

  validation {
    condition     = var.api_throttle_rate_limit >= 1 && var.api_throttle_rate_limit <= 100
    error_message = "api_throttle_rate_limit must be between 1 and 100 (lab cost guard)."
  }
}

variable "api_throttle_burst_limit" {
  type        = number
  description = "Burst of requests the HTTP API stage accepts above the rate (ADR 0012 L2)."
  default     = 10

  validation {
    condition     = var.api_throttle_burst_limit >= 1 && var.api_throttle_burst_limit <= 200 && floor(var.api_throttle_burst_limit) == var.api_throttle_burst_limit
    error_message = "api_throttle_burst_limit must be a whole number between 1 and 200 (lab cost guard)."
  }
}

variable "alarm_topic_arn" {
  type        = string
  description = "SNS topic for the three alarms (the bootstrap <prefix>-<env>-security-alerts topic). Null: alarms without actions."
  default     = null

  validation {
    condition     = var.alarm_topic_arn == null || can(regex("^arn:[a-z-]+:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be null or an SNS topic ARN."
  }
}
