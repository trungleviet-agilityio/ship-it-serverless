# The web function (ADR 0012 L1, L3): the app image with the Lambda Web Adapter extension, package type Image.
# Terraform owns the shape (memory, timeout, role, env, logging, concurrency); App Deploy owns which image and which
# version serve (ADR 0005 F2 as rewritten by L3), so image_uri and IMAGE_DIGEST are ignored after the create.
resource "aws_lambda_function" "app" {
  function_name = local.names.function
  description   = "Board web app behind the Lambda Web Adapter (ADR 0012)"
  role          = aws_iam_role.exec.arn
  package_type  = "Image"
  image_uri     = local.initial_image_uri
  architectures = ["x86_64"] # L12: the runner builds amd64 natively
  memory_size   = var.memory_mb
  timeout       = var.timeout_s

  # -1 is the provider's "no reservation" value (unreserved account concurrency); null in the input means that.
  # A reservation is a second cost cap where the account quota allows one (L10, Finding 10).
  reserved_concurrent_executions = var.reserved_concurrency == null ? -1 : var.reserved_concurrency

  # Every Terraform change publishes a version too, and the first one is what the alias starts on.
  publish = true

  environment {
    variables = {
      APP_ENV = var.env
      # Lambda Web Adapter (Finding 1): the app listens on 8080 and is ready when /health answers.
      AWS_LWA_PORT                 = "8080"
      AWS_LWA_READINESS_CHECK_PATH = "/health"
      # The app reads the value itself (L5); this is the ARN, never the value.
      APP_API_KEY_SECRET_ARN = aws_secretsmanager_secret.app.arn
      # L6: the deploy sets this before every PublishVersion; Terraform only seeds it.
      IMAGE_DIGEST = local.initial_image_digest
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  # The log group must exist before the first invoke, and the role policy before the function can log.
  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.exec]

  lifecycle {
    # L3: App Deploy swaps the image by digest and sets IMAGE_DIGEST; a Terraform apply must not revert either.
    ignore_changes = [image_uri, environment[0].variables["IMAGE_DIGEST"]]
  }
}

# The stable name the HTTP API invokes (L2). Created on the version published at create; afterwards App Deploy moves
# it (L7 all-at-once or canary weights, L8 rollback), so Terraform ignores the version and the routing.
resource "aws_lambda_alias" "live" {
  name             = local.names.alias
  description      = "Serving version; moved by App Deploy (ADR 0012 L7)"
  function_name    = aws_lambda_function.app.function_name
  function_version = aws_lambda_function.app.version

  lifecycle {
    ignore_changes = [function_version, routing_config]
  }
}
