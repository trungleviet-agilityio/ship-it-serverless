# What the module must create and must not allow (ADR 0012 L2, L3, L9, L10). Offline: nothing talks to AWS.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

# The newest image in the bootstrap repository (L3).
override_data {
  target = data.aws_ecr_image.app
  values = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
}

# Computed attributes are unknown at plan time; pin the ones the assertions compare.
override_resource {
  override_during = plan
  target          = aws_secretsmanager_secret.app
  values          = { arn = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-AbCdEf" }
}
override_resource {
  override_during = plan
  target          = aws_cloudwatch_log_group.lambda
  values          = { arn = "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-app" }
}
override_resource {
  override_during = plan
  target          = aws_cloudwatch_log_group.api
  values          = { arn = "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/apigateway/sis-dev-api" }
}
override_resource {
  override_during = plan
  target          = aws_iam_role.exec
  values          = { arn = "arn:aws:iam::123456789012:role/sis-dev-app-exec" }
}
override_resource {
  override_during = plan
  target          = aws_lambda_function.app
  values = {
    arn     = "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app"
    version = "1"
  }
}
override_resource {
  override_during = plan
  target          = aws_lambda_alias.live
  values          = { arn = "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app:live" }
}
override_resource {
  override_during = plan
  target          = aws_apigatewayv2_api.this
  values = {
    id            = "abc123defg"
    execution_arn = "arn:aws:execute-api:ap-southeast-1:123456789012:abc123defg"
  }
}
override_resource {
  override_during = plan
  target          = aws_apigatewayv2_integration.app
  values          = { id = "int0001" }
}

variables {
  prefix     = "sis"
  env        = "dev"
  aws_region = "ap-southeast-1"
}

run "names_follow_the_bootstrap_contract" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.app.function_name == "sis-dev-app"
      && aws_lambda_alias.live.name == "live"
      && aws_apigatewayv2_api.this.name == "sis-dev-api"
      && aws_iam_role.exec.name == "sis-dev-app-exec"
      && aws_cloudwatch_log_group.lambda.name == "/aws/lambda/sis-dev-app"
      && aws_cloudwatch_log_group.api.name == "/aws/apigateway/sis-dev-api"
      && aws_secretsmanager_secret.app.name == "sis/dev/app-api-key"
      && data.aws_ecr_image.app.repository_name == "sis-dev-app"
    )
    error_message = "every name must equal the bootstrap resource_names contract"
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.lambda_errors.alarm_name == "sis-dev-app-errors"
      && aws_cloudwatch_metric_alarm.lambda_throttles.alarm_name == "sis-dev-app-throttles"
      && aws_cloudwatch_metric_alarm.api_5xx.alarm_name == "sis-dev-api-5xx"
    )
    error_message = "alarm names are <prefix>-<env>-app-errors, -app-throttles and -api-5xx (the apply role allows alarm:sis-dev-*)"
  }
}

run "function_runs_the_image_by_digest" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.app.package_type == "Image"
      && aws_lambda_function.app.image_uri == "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"
      && data.aws_ecr_image.app.most_recent == true
    )
    error_message = "the function is created from the newest bootstrap image, pinned by digest (L3)"
  }

  assert {
    condition = (
      aws_lambda_function.app.architectures == tolist(["x86_64"])
      && aws_lambda_function.app.memory_size == 512
      && aws_lambda_function.app.timeout == 10
      && aws_lambda_function.app.publish == true
      && aws_lambda_function.app.role == aws_iam_role.exec.arn
      && aws_lambda_function.app.reserved_concurrent_executions == -1
    )
    error_message = "x86_64, 512 MB, 10 s, publish, the execution role, no reserved concurrency by default"
  }

  assert {
    condition = one(aws_lambda_function.app.environment).variables == tomap({
      APP_ENV                      = "dev"
      AWS_LWA_PORT                 = "8080"
      AWS_LWA_READINESS_CHECK_PATH = "/health"
      APP_API_KEY_SECRET_ARN       = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-AbCdEf"
      IMAGE_DIGEST                 = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    })
    error_message = "the environment holds exactly APP_ENV, the LWA settings, the secret ARN (never a value) and the initial IMAGE_DIGEST"
  }

  assert {
    condition = (
      one(aws_lambda_function.app.logging_config).log_group == "/aws/lambda/sis-dev-app"
      && one(aws_lambda_function.app.logging_config).log_format == "Text"
    )
    error_message = "the function logs to its Terraform-managed log group"
  }
}

# FR-8, L5: the key value never sits in the function configuration; only the secret ARN does.
run "environment_never_holds_the_api_key" {
  command = plan

  assert {
    condition = (
      !contains(keys(one(aws_lambda_function.app.environment).variables), "APP_API_KEY")
      && !contains(keys(local.function_environment), "APP_API_KEY")
      && startswith(one(aws_lambda_function.app.environment).variables["APP_API_KEY_SECRET_ARN"], "arn:aws:secretsmanager:")
    )
    error_message = "APP_API_KEY must never be in the function environment; the app gets the secret through APP_API_KEY_SECRET_ARN"
  }
}

# B1: the deploy owns the description after the create; Terraform only seeds one that never looks like a release.
run "description_is_an_initial_seed" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.app.description == "initial image (terraform create) sha256:1111111111111111111111111111111111111111111111111111111111111111"
      && !strcontains(aws_lambda_function.app.description, "sha=")
    )
    error_message = "the create seeds the description with the initial digest, never in the deploy's sha=<sha> digest=<digest> form"
  }
}

run "api_integration_method_is_post" {
  command = plan

  assert {
    condition     = aws_apigatewayv2_integration.app.integration_method == "POST"
    error_message = "the AWS_PROXY integration calls Lambda with POST (the provider requires a method unless the type is MOCK)"
  }
}

run "reserved_concurrency_is_passed_through" {
  command = plan

  variables {
    reserved_concurrency = 5
  }

  assert {
    condition     = aws_lambda_function.app.reserved_concurrent_executions == 5
    error_message = "a set reserved_concurrency reaches the function"
  }
}

run "alias_starts_on_the_published_version" {
  command = plan

  assert {
    condition = (
      aws_lambda_alias.live.function_name == "sis-dev-app"
      && aws_lambda_alias.live.function_version == "1"
    )
    error_message = "live points at the version published at create"
  }
}

run "api_invokes_the_alias_only" {
  command = plan

  assert {
    condition = (
      aws_apigatewayv2_api.this.protocol_type == "HTTP"
      && aws_apigatewayv2_integration.app.integration_type == "AWS_PROXY"
      && aws_apigatewayv2_integration.app.integration_method == "POST"
      && aws_apigatewayv2_integration.app.integration_uri == "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app:live"
      && aws_apigatewayv2_integration.app.payload_format_version == "2.0"
      && aws_apigatewayv2_integration.app.timeout_milliseconds <= 30000
    )
    error_message = "HTTP API with an AWS_PROXY integration (method POST) on the alias ARN, payload 2.0, timeout within 30 s"
  }

  assert {
    condition = (
      aws_apigatewayv2_route.default.route_key == "$default"
      && aws_apigatewayv2_route.default.target == "integrations/int0001"
      && aws_apigatewayv2_stage.default.name == "$default"
      && aws_apigatewayv2_stage.default.auto_deploy == true
    )
    error_message = "one $default route to the integration, $default stage with auto-deploy"
  }

  assert {
    condition = (
      aws_lambda_permission.api.action == "lambda:InvokeFunction"
      && aws_lambda_permission.api.principal == "apigateway.amazonaws.com"
      && aws_lambda_permission.api.function_name == "sis-dev-app"
      && aws_lambda_permission.api.qualifier == "live"
      && aws_lambda_permission.api.source_arn == "arn:aws:execute-api:ap-southeast-1:123456789012:abc123defg/*/*"
    )
    error_message = "the API may invoke only the live alias, and only from this API"
  }
}

run "stage_throttling_and_access_log" {
  command = plan

  assert {
    condition = (
      one(aws_apigatewayv2_stage.default.default_route_settings).throttling_rate_limit == 5
      && one(aws_apigatewayv2_stage.default.default_route_settings).throttling_burst_limit == 10
    )
    error_message = "stage throttling defaults to 5 requests/s with a burst of 10 (L2)"
  }

  assert {
    condition = (
      one(aws_apigatewayv2_stage.default.access_log_settings).destination_arn == "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/apigateway/sis-dev-api"
      && alltrue([
        for k in ["requestId", "routeKey", "status", "integrationStatus", "responseLatency", "ip"] :
        contains(keys(jsondecode(one(aws_apigatewayv2_stage.default.access_log_settings).format)), k)
      ])
      && !strcontains(lower(one(aws_apigatewayv2_stage.default.access_log_settings).format), "header")
      && !strcontains(lower(one(aws_apigatewayv2_stage.default.access_log_settings).format), "authorizer")
    )
    error_message = "JSON access log to the API log group with the request fields, never headers"
  }
}

run "throttling_follows_the_inputs" {
  command = plan

  variables {
    api_throttle_rate_limit  = 2
    api_throttle_burst_limit = 4
  }

  assert {
    condition = (
      one(aws_apigatewayv2_stage.default.default_route_settings).throttling_rate_limit == 2
      && one(aws_apigatewayv2_stage.default.default_route_settings).throttling_burst_limit == 4
    )
    error_message = "throttling comes from the inputs"
  }
}

run "log_retention" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.lambda.retention_in_days == 7 && aws_cloudwatch_log_group.api.retention_in_days == 7
    error_message = "both log groups keep 7 days by default"
  }
}

run "exec_role_is_bounded" {
  command = plan

  assert {
    condition = (
      aws_iam_role.exec.permissions_boundary == "arn:aws:iam::123456789012:policy/sis-dev-app-boundary"
      && aws_iam_role.exec.max_session_duration == 3600
    )
    error_message = "the execution role carries the bootstrap boundary"
  }
}

run "secret_is_a_shell" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.app.recovery_window_in_days == 0
    error_message = "recovery window defaults to 0 so a torn-down stack can be re-created"
  }
}

run "alarms_without_topic" {
  command = plan

  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.lambda_errors, aws_cloudwatch_metric_alarm.lambda_throttles, aws_cloudwatch_metric_alarm.api_5xx] :
      length(a.alarm_actions) == 0 && a.treat_missing_data == "notBreaching" && a.period == 60 && a.statistic == "Sum"
    ])
    error_message = "without a topic the alarms have no actions; 1-minute Sum, missing data is not breaching"
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.lambda_errors.namespace == "AWS/Lambda"
      && aws_cloudwatch_metric_alarm.lambda_errors.metric_name == "Errors"
      && aws_cloudwatch_metric_alarm.lambda_errors.dimensions == tomap({ FunctionName = "sis-dev-app", Resource = "sis-dev-app:live" })
      && aws_cloudwatch_metric_alarm.lambda_throttles.namespace == "AWS/Lambda"
      && aws_cloudwatch_metric_alarm.lambda_throttles.metric_name == "Throttles"
      && aws_cloudwatch_metric_alarm.lambda_throttles.dimensions == tomap({ FunctionName = "sis-dev-app", Resource = "sis-dev-app:live" })
    )
    error_message = "Lambda Errors and Throttles on the live alias (Resource = <function>:live)"
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.api_5xx.namespace == "AWS/ApiGateway"
      && aws_cloudwatch_metric_alarm.api_5xx.metric_name == "5xx"
      && aws_cloudwatch_metric_alarm.api_5xx.dimensions == tomap({ ApiId = "abc123defg", Stage = "$default" })
    )
    error_message = "HTTP API 5xx on this API's $default stage"
  }
}

run "alarms_notify_the_topic" {
  command = plan

  variables {
    alarm_topic_arn = "arn:aws:sns:ap-southeast-1:123456789012:sis-dev-security-alerts"
  }

  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.lambda_errors, aws_cloudwatch_metric_alarm.lambda_throttles, aws_cloudwatch_metric_alarm.api_5xx] :
      a.alarm_actions == toset(["arn:aws:sns:ap-southeast-1:123456789012:sis-dev-security-alerts"])
    ])
    error_message = "every alarm notifies the topic it is given"
  }
}

run "outputs" {
  command = plan

  assert {
    condition = (
      output.function_name == "sis-dev-app"
      && output.alias_name == "live"
      && output.ecr_repository_url == "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app"
      && output.lambda_log_group_name == "/aws/lambda/sis-dev-app"
      && output.api_log_group_name == "/aws/apigateway/sis-dev-api"
      && output.secret_name == "sis/dev/app-api-key"
      && output.exec_role_name == "sis-dev-app-exec"
    )
    error_message = "outputs carry the contract names"
  }
}

# Input validation.

run "rejects_memory_above_the_cap" {
  command = plan
  variables {
    memory_mb = 4096
  }
  expect_failures = [var.memory_mb]
}

run "rejects_timeout_above_the_api_limit" {
  command = plan
  variables {
    timeout_s = 31
  }
  expect_failures = [var.timeout_s]
}

run "rejects_zero_reserved_concurrency" {
  command = plan
  variables {
    reserved_concurrency = 0
  }
  expect_failures = [var.reserved_concurrency]
}

run "rejects_odd_log_retention" {
  command = plan
  variables {
    log_retention_days = 10
  }
  expect_failures = [var.log_retention_days]
}

run "rejects_zero_throttle_rate" {
  command = plan
  variables {
    api_throttle_rate_limit = 0
  }
  expect_failures = [var.api_throttle_rate_limit]
}

run "rejects_fractional_burst" {
  command = plan
  variables {
    api_throttle_burst_limit = 2.5
  }
  expect_failures = [var.api_throttle_burst_limit]
}

run "rejects_a_non_sns_topic" {
  command = plan
  variables {
    alarm_topic_arn = "arn:aws:sqs:ap-southeast-1:123456789012:sis-dev-queue"
  }
  expect_failures = [var.alarm_topic_arn]
}

run "rejects_short_secret_window" {
  command = plan
  variables {
    secret_recovery_window_days = 3
  }
  expect_failures = [var.secret_recovery_window_days]
}

run "rejects_uppercase_env" {
  command = plan
  variables {
    env = "Dev"
  }
  expect_failures = [var.env]
}

run "rejects_bad_region" {
  command = plan
  variables {
    aws_region = "apsoutheast1"
  }
  expect_failures = [var.aws_region]
}
