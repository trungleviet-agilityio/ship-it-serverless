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
  # GetFunctionRecursionConfig is defensive: the provider may read it on refresh; read only, same scope.
  # RemovePermission stays here without the lambda:Principal condition of LambdaAddPermissionApiGateway: removing
  # a permission can only narrow who may invoke, and a condition key the request lacked would block a destroy.
  statement {
    sid    = "LambdaFunction"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:GetFunctionRecursionConfig",
      "lambda:GetRuntimeManagementConfig",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:PublishVersion",
      "lambda:ListVersionsByFunction",
      "lambda:CreateAlias",
      "lambda:DeleteAlias",
      "lambda:GetAlias",
      "lambda:UpdateAlias",
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

  # The only resource-based permission the module adds is the HTTP API's (aws_lambda_permission.api). AddPermission
  # supports the lambda:Principal condition key (Service Authorization Reference, AWS Lambda), so the apply role can
  # never grant invoke to another account or service, or create a public Function URL permission.
  statement {
    sid       = "LambdaAddPermissionApiGateway"
    effect    = "Allow"
    actions   = ["lambda:AddPermission"]
    resources = local.function_arns_env

    condition {
      test     = "StringEquals"
      variable = "lambda:Principal"
      values   = ["apigateway.amazonaws.com"]
    }
  }

  # The one repository, read only; the repository and its policy belong to bootstrap (L4).
  # - DescribeImages, DescribeRepositories: data "aws_ecr_image" (most_recent) finds the newest image (L3).
  # - BatchGetImage, GetDownloadUrlForLayer, GetRepositoryPolicy: CreateFunction and UpdateFunctionCode with an
  #   image need them on the caller (Lambda Developer Guide, "Create a function using a container image").
  # The same page lists ecr:SetRepositoryPolicy, which exists so Lambda can add its own pull statement to the
  # repository policy. It is not granted: bootstrap owns the policy and LambdaPull (ecr.tf) already allows
  # lambda.amazonaws.com. The live checkpoint confirms that CreateFunction works without it.
  statement {
    sid    = "EcrReadOneRepo"
    effect = "Allow"
    actions = [
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
    ]
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
  # DeleteLogDelivery, ListLogDeliveries, PutResourcePolicy, DescribeResourcePolicies and DescribeLogGroups are
  # believed to support no resource-level permissions, so they take "*". Accepted risk: the Service Authorization
  # Reference could not be opened offline to confirm the resource types; re-check it at the live checkpoint and
  # scope any action that does support a resource (PutResourcePolicy can widen log group access account-wide).
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

  # Secret shells only. Guardrail G1 denies reading values (GetSecretValue, BatchGetSecretValue) and PutSecretValue,
  # but CreateSecret and UpdateSecret accept SecretString, so this role could still write a value through them.
  # Accepted risk (ADR 0002 R1): the module never sets one (no secret version resource, tf/policy.sh rule 1), and a
  # value written this way could not be read back by any CI role.
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

  # IAM on the execution role, exact ARN only (not a <name>-app-* pattern: the module creates one role, and a
  # wildcard role pattern fails the M1 test). Each condition sits only on actions that support its key: an action
  # without iam:PermissionsBoundary in its request context would never match a StringEquals on it and would be
  # implicitly denied.

  # The role can only be created or given policies with the boundary attached (B15, L9). Per the IAM Service
  # Authorization Reference, iam:PermissionsBoundary is supported by CreateRole, PutRolePolicy, DeleteRolePolicy,
  # PutRolePermissionsBoundary (and AttachRolePolicy, DetachRolePolicy, DeleteRolePermissionsBoundary, which this
  # role does not hold or is denied).
  statement {
    sid    = "IamAppRoleBounded"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.app_exec_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  # Trust change and delete. Neither supports iam:PermissionsBoundary (not in the reference's list above; re-check
  # at the live checkpoint), so a boundary condition here would not constrain them, it would only deny them.
  # UpdateAssumeRolePolicy could give the role a foreign trust: the boundary still caps the role, and its secret
  # read requires lambda:SourceFunctionArn of this env's function (iam_app_boundary.tf), which a request from
  # outside the function never carries. DeleteRole only removes the role; DenyBoundaryRemoval stays in force.
  statement {
    sid    = "IamAppRoleTrustAndDelete"
    effect = "Allow"
    actions = [
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
    ]
    resources = [local.app_exec_role_arn]
  }

  # Tags, description and maximum session duration. TagRole, UntagRole, UpdateRole and UpdateRoleDescription do not
  # support iam:PermissionsBoundary either. None of them can widen what the role may do, and the boundary still caps
  # the role whatever its tags or description say.
  statement {
    sid    = "IamAppRoleMetadata"
    effect = "Allow"
    actions = [
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = [local.app_exec_role_arn]
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
