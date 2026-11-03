resource "aws_iam_role" "apply" {
  name                 = local.role_names.apply
  description          = "GitHub Actions apply for envs/<env>, scoped to the services of modules/app-lambda"
  path                 = "/"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
}

# ADR 0012 L9 (FR-4 rewritten): state as before, then exactly what modules/app-lambda creates. The ECR repository
# lives in bootstrap (L4), so the apply role only reads it. EC2, ELB, ECS and ECR-write statements are gone with ECS
# (L11).
data "aws_iam_policy_document" "apply" {
  # State access (B18).
  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = local.state_list_prefixes
    }
  }

  statement {
    sid       = "StateReadWrite"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.state_arn]
  }

  statement {
    sid       = "StateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.lock_arn]
  }

  # Function, alias, permission, concurrency and tags (L3), as the aws provider calls them for aws_lambda_function,
  # aws_lambda_alias and aws_lambda_permission. Scoped to this env's functions and their qualified ARNs.
  # UpdateFunctionCode stays: architectures is set through it, even though Terraform ignores image_uri.
  statement {
    sid    = "LambdaFunction"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:GetRuntimeManagementConfig",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:PublishVersion",
      "lambda:ListVersionsByFunction",
      "lambda:CreateAlias",
      "lambda:DeleteAlias",
      "lambda:GetAlias",
      "lambda:UpdateAlias",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
      "lambda:PutFunctionConcurrency",
      "lambda:DeleteFunctionConcurrency",
      "lambda:GetFunctionConcurrency",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
    ]
    resources = local.function_arns_env
  }

  # data "aws_ecr_image" (most_recent) picks the first image of the one repository (L3). Read only: the repository
  # and its policy belong to bootstrap (L4).
  statement {
    sid       = "EcrReadOneRepo"
    effect    = "Allow"
    actions   = ["ecr:DescribeImages", "ecr:DescribeRepositories"]
    resources = [local.ecr_repo_app]
  }

  # HTTP API, integration, route and stage (L2). API Gateway authorizes by HTTP verb on the resource path. API IDs
  # are random, so the paths are every HTTP API of this region; tags are written through POST/DELETE on /tags/*.
  statement {
    sid    = "ApiGatewayHttpApi"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
    ]
    resources = [
      "${local.apigateway_arn}/apis",
      "${local.apigateway_arn}/apis/*",
      "${local.apigateway_arn}/tags/*",
    ]
  }

  # The two log groups (L10): the function's and the HTTP API access log.
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:TagLogGroup",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
    ]
    resources = local.log_group_arns
  }

  # API Gateway HTTP API access logging permissions: the caller that sets access_log_settings on a stage needs the
  # CloudWatch Logs vended-delivery actions. CreateLogDelivery, GetLogDelivery, UpdateLogDelivery,
  # DeleteLogDelivery, ListLogDeliveries, PutResourcePolicy, DescribeResourcePolicies and DescribeLogGroups support
  # no resource-level permissions (Service Authorization Reference), so they take "*".
  statement {
    sid    = "LogsDeliveryUnscoped"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"] # No resource-level support (see above)
  }

  # The three alarms (L10), all named <prefix>-<env>-*.
  statement {
    sid    = "CloudWatchAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = ["${local.svc_arn["cloudwatch"]}:alarm:${local.name}-*"]
  }

  # Secret shells only: G1 denies reading or writing values.
  statement {
    sid    = "SecretShell"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:UpdateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]
    resources = [local.secret_pattern]
  }

  # The execution role can only be created or changed with the boundary attached (B15, L9). Exact ARN, not a
  # <name>-app-* pattern: the module creates one role, and a wildcard role pattern fails the M1 test.
  statement {
    sid    = "IamAppRoleBounded"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
    ]
    resources = [local.app_exec_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid    = "IamAppRoleRead"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = [local.app_exec_role_arn]
  }

  # CreateFunction and UpdateFunctionConfiguration with a Role need PassRole (Finding 9): the one execution role,
  # to Lambda only.
  statement {
    sid       = "PassAppExecRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.app_exec_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # API Gateway creates its service-linked role on first use in an account.
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["${local.iam_arn}:role/aws-service-role/ops.apigateway.amazonaws.com/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ops.apigateway.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
