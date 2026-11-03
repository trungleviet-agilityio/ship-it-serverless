# Front door (ADR 0012 L2): HTTP API, one $default route, $default stage with auto-deploy, stage throttling as the
# cost ceiling, JSON access logs.
resource "aws_apigatewayv2_api" "this" {
  name          = local.names.api
  protocol_type = "HTTP"
  description   = "Front door of ${local.names.function} (ADR 0012 L2)"
}

# AWS_PROXY on the alias ARN, so traffic always follows `live` (canary weights included). For an HTTP API the Lambda
# integration URI is the function ARN, here qualified with the alias. Payload 2.0 is what the Lambda Web Adapter
# reads for HTTP APIs. 29 s is below the HTTP API maximum of 30 s and far above the 10 s function timeout.
resource "aws_apigatewayv2_integration" "app" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.live.arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

# One route for every method and path: the app does its own routing (a "Lambdalith").
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.app.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # R1: throttling works in any account, whatever the concurrency quota (Finding 10). Excess requests get 429.
  default_route_settings {
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }

  # One JSON line per request. Request metadata only: no header, body, query string or auth value is ever logged,
  # so the API key cannot reach the logs.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId         = "$context.requestId"
      requestTime       = "$context.requestTime"
      routeKey          = "$context.routeKey"
      status            = "$context.status"
      integrationStatus = "$context.integrationStatus"
      responseLatency   = "$context.responseLatency"
      ip                = "$context.identity.sourceIp"
    })
  }
}

# The API may invoke the alias, and nothing else: qualifier `live`, source = this API (any stage, any route).
resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApiInvokeLive"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
