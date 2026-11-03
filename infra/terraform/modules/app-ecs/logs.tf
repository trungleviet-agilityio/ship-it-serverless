resource "aws_cloudwatch_log_group" "app" {
  name              = local.names.log_group
  retention_in_days = var.log_retention_days
}
