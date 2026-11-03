# Both log groups are created by Terraform with a retention (ADR 0012 L10), so neither Lambda nor API Gateway
# creates an unbounded one, and the execution role needs no logs:CreateLogGroup.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = local.names.lambda_log_group
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "api" {
  name              = local.names.api_log_group
  retention_in_days = var.log_retention_days
}
