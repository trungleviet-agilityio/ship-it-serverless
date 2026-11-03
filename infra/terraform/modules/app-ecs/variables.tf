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
  description = "AWS region of the stack. Used for the awslogs driver and the task role trust."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like ap-southeast-1."
  }
}

variable "azs" {
  type        = list(string)
  description = "Exactly two availability zones, one public subnet each."

  validation {
    condition     = length(var.azs) == 2
    error_message = "azs must hold exactly 2 availability zones."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block of the VPC. Subnets are /24 slices of it."
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "container_image" {
  type        = string
  description = "Container image pinned by digest (NFR-3)."

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.container_image))
    error_message = "container_image must be pinned by digest: <repository>@sha256:<64 hex>."
  }
}

variable "container_port" {
  type        = number
  description = "Port the container listens on."
  default     = 8080

  validation {
    condition     = var.container_port >= 1024 && var.container_port <= 65535
    error_message = "container_port must be between 1024 and 65535 (the container runs as a non-root user)."
  }
}

variable "health_check_path" {
  type        = string
  description = "HTTP path the load balancer probes."
  default     = "/health"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must start with /."
  }
}

variable "task_cpu" {
  type        = number
  description = "Task-level CPU units. The apply role caps this at 512 (ecs:task-cpu)."
  default     = 256

  validation {
    condition     = contains([256, 512], var.task_cpu)
    error_message = "task_cpu must be 256 or 512 (the apply role refuses more)."
  }
}

variable "task_memory" {
  type        = number
  description = "Task-level memory in MiB. The apply role caps this at 1024 (ecs:task-memory)."
  default     = 512

  validation {
    condition     = var.task_memory >= 512 && var.task_memory <= 1024
    error_message = "task_memory must be between 512 and 1024 (the apply role refuses more)."
  }
}

variable "desired_count" {
  type        = number
  description = "Number of tasks."
  default     = 1

  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 2
    error_message = "desired_count must be 0, 1 or 2."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the application log group."
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30], var.log_retention_days)
    error_message = "log_retention_days must be one of 1, 3, 5, 7, 14, 30."
  }
}

variable "ecr_keep_images" {
  type        = number
  description = "Number of images the ECR lifecycle rule keeps."
  default     = 10

  validation {
    condition     = var.ecr_keep_images >= 1
    error_message = "ecr_keep_images must be at least 1."
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

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the ALB on port 80. Open by default (ADR 0004, Q1); restrict it when the lab is not being demoed."
  default     = ["0.0.0.0/0"]
  sensitive   = true # may be a maintainer address from a repository secret (ADR 0007 S10)

  validation {
    condition     = length(var.alb_ingress_cidrs) >= 1 && alltrue([for c in var.alb_ingress_cidrs : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", c)) && can(cidrhost(c, 0))])
    error_message = "alb_ingress_cidrs must hold at least one valid IPv4 CIDR block (the rules use cidr_ipv4)."
  }
}

variable "promotion_target_env" {
  type        = string
  description = "Environment that promotes images from this repository (ADR 0008 P9), e.g. \"prod\" in dev. Empty: no repository policy."
  default     = ""

  validation {
    condition     = var.promotion_target_env == "" || can(regex("^[a-z][a-z0-9]{1,7}$", var.promotion_target_env))
    error_message = "promotion_target_env must be empty or 2 to 8 lowercase letters and digits, starting with a letter."
  }
}

variable "promotion_target_account_id" {
  type        = string
  description = "Account of promotion_target_env. Required when promotion_target_env is set, ignored otherwise; sensitive so it never prints in a public plan."
  default     = ""
  sensitive   = true

  validation {
    condition     = var.promotion_target_env == "" || can(regex("^[0-9]{12}$", var.promotion_target_account_id))
    error_message = "promotion_target_account_id must be 12 digits when promotion_target_env is set (it is ignored otherwise)."
  }
}
