resource "aws_iam_role" "deploy" {
  name                 = local.role_names.deploy
  description          = "GitHub Actions deploy: push one image, publish and route one function"
  path                 = "/"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.trust["deploy"].json
}

# ADR 0012 L9 (FR-5 rewritten): one repository, one function. The trust is unchanged (same workflow files).
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # No resource-level support
  }

  statement {
    sid    = "EcrPushOneRepo"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [local.ecr_repo_app]
  }

  # Promoted environments only (ADR 0008 P9): pull the image by digest from the one source repository. The source
  # repository policy must also allow this role (bootstrap ecr.tf PromotionPull in the source account, set through
  # promotion_target_account_id), so both accounts agree.
  dynamic "statement" {
    for_each = local.is_promoted ? [local.ecr_repo_source] : []
    content {
      sid       = "EcrPullFromSource"
      effect    = "Allow"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      resources = [statement.value]
    }
  }

  # The release steps of L6 to L8 on the one function and its versions and alias: swap the image by digest, set
  # IMAGE_DIGEST, publish, smoke-invoke the new version, move or weight the alias. UpdateFunctionConfiguration can
  # change env values, memory and timeout (R4) but never the role: there is no PassRole (DenyPassRole below).
  statement {
    sid    = "LambdaReleaseOneFunction"
    effect = "Allow"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:PublishVersion",
      "lambda:ListVersionsByFunction",
      "lambda:GetAlias",
      "lambda:UpdateAlias",
      "lambda:InvokeFunction",
    ]
    resources = [local.function_arn_app, "${local.function_arn_app}:*"]
  }

  # Version pruning (L8). Qualified ARNs only: DeleteFunction with a qualifier deletes one version, and the
  # unqualified function ARN is not matched, so the function itself can never be deleted by the deploy.
  statement {
    sid       = "LambdaPruneVersions"
    effect    = "Allow"
    actions   = ["lambda:DeleteFunction"]
    resources = ["${local.function_arn_app}:*"]
  }

  # The deploy finds the API endpoint by name (GetApis) to probe /health and /version through the front door.
  statement {
    sid       = "ApiGatewayRead"
    effect    = "Allow"
    actions   = ["apigateway:GET"]
    resources = ["${local.apigateway_arn}/apis", "${local.apigateway_arn}/apis/*"]
  }

  # Canary judgment (L7): Errors for the new version (dimension ExecutedVersion).
  statement {
    sid       = "CanaryMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:GetMetricStatistics"]
    resources = ["*"] # No resource-level support
  }

  # Metadata only (ADR 0006, G14): the preflight checks that the secret has a current version. The G1 guardrail
  # still denies reading or writing a value. The six "?" match the random suffix, so only this one secret matches.
  statement {
    sid       = "DescribeAppSecretMetadata"
    effect    = "Allow"
    actions   = ["secretsmanager:DescribeSecret"]
    resources = ["${local.svc_arn["secretsmanager"]}:secret:${local.resource_names.secret}-??????"]
  }

  # Finding 9: without PassRole the deploy can update code and env values but never attach another execution role.
  # Explicit, so a future Allow (or a managed policy) cannot add it back.
  statement {
    sid       = "DenyPassRole"
    effect    = "Deny"
    actions   = ["iam:PassRole"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
