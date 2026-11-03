# The web function (ADR 0012 L1, L3): the app image with the Lambda Web Adapter extension, package type Image.
# Terraform owns the shape (memory, timeout, role, env, logging, concurrency); App Deploy owns which image and which
# version serve (ADR 0005 F2 as rewritten by L3), so image_uri, IMAGE_DIGEST and description are ignored after the
# create.
resource "aws_lambda_function" "app" {
  function_name = local.names.function
  # Seed only. App Deploy writes "sha=<sha> digest=<digest>" together with IMAGE_DIGEST before every PublishVersion
  # (L6, L7): PublishVersion publishes nothing new when code and configuration are unchanged, so the description is
  # what makes each release a distinct version, and the rollback lookup (L8) matches it exactly. This seed never
  # has that form, so the version published at create is never mistaken for a release.
  description   = "initial image (terraform create) ${local.initial_image_digest}"
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
    variables = local.function_environment
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  # The log group must exist before the first invoke, and the role policy before the function can log.
  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.exec]

  lifecycle {
    # L3: App Deploy swaps the image by digest and sets IMAGE_DIGEST and the description; a Terraform apply must not
    # revert any of them.
    ignore_changes = [image_uri, environment[0].variables["IMAGE_DIGEST"], description]

    # FR-8, L5: the key value never reaches the function configuration (GetFunctionConfiguration shows env values
    # to anyone who may read the function, and Terraform state would hold it). Only its ARN does.
    precondition {
      condition     = !contains(keys(local.function_environment), "APP_API_KEY")
      error_message = "The function environment must not contain APP_API_KEY: the app reads the value itself through APP_API_KEY_SECRET_ARN (ADR 0012 L5, FR-8)."
    }
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
