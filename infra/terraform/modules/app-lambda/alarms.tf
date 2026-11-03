# ADR 0012 L10: three 1-minute alarms. Actions go to the bootstrap topic <prefix>-<env>-security-alerts when the env
# passes it; missing data (no traffic) is not an alarm.

# Errors of the version(s) behind `live`: the Resource dimension "<function>:<alias>" selects the alias.
# What it counts: Lambda Errors are invocations that fail in the function (a crash, an unhandled error, a
# timeout). With the Lambda Web Adapter an HTTP 500 from the app is a successful invoke that returns a 500 response,
# so it is not an Error; the api_5xx alarm below is the signal for app 500s.
# The alias-level metric (FunctionName + Resource = <function>:live) aggregates every version behind the alias,
# canary weights included: during a canary it mixes old and new versions. The canary judgment (L7) reads Errors by
# ExecutedVersion instead.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = local.names.alarm_errors
  alarm_description   = "Lambda Errors on ${local.names.function}:${local.names.alias} (ADR 0012 L10)"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.names.function, Resource = "${local.names.function}:${local.names.alias}" }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  depends_on = [aws_lambda_alias.live]
}

# Throttles: reserved concurrency (when set) or the account quota was hit.
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = local.names.alarm_throttles
  alarm_description   = "Lambda Throttles on ${local.names.function}:${local.names.alias} (ADR 0012 L10)"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = local.names.function, Resource = "${local.names.function}:${local.names.alias}" }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  depends_on = [aws_lambda_alias.live]
}

# Server errors at the front door (integration failures, timeouts and 5xx answers from the app).
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = local.names.alarm_api_5xx
  alarm_description   = "HTTP API 5xx on ${local.names.api}, stage $default (ADR 0012 L10)"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.this.id, Stage = aws_apigatewayv2_stage.default.name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}
