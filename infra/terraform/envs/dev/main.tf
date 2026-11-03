module "app_lambda" {
  source = "../../modules/app-lambda"

  prefix                      = var.prefix
  env                         = var.env
  aws_region                  = var.aws_region
  memory_mb                   = var.memory_mb
  timeout_s                   = var.timeout_s
  log_retention_days          = var.log_retention_days
  secret_recovery_window_days = var.secret_recovery_window_days
  reserved_concurrency        = var.reserved_concurrency
  api_throttle_rate_limit     = var.api_throttle_rate_limit
  api_throttle_burst_limit    = var.api_throttle_burst_limit
  alarm_topic_arn             = local.alarm_topic_arn
}
