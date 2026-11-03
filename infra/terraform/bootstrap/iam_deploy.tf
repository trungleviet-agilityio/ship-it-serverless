locals {
  # Every revision of the app family, and the one service the deploy role may describe and update.
  task_definition_arn_pattern = "${local.svc_arn["ecs"]}:task-definition/${local.resource_names.task_family}:*"
  service_arn                 = "${local.svc_arn["ecs"]}:service/${local.resource_names.ecs_cluster}/${local.resource_names.ecs_service}"
}

resource "aws_iam_role" "deploy" {
  name                 = local.role_names.deploy
  description          = "GitHub Actions deploy: push one image, roll one service"
  path                 = "/"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.trust["deploy"].json
}

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
  # repository policy must also allow this role (modules/app-ecs, promotion_target_*), so both accounts agree.
  dynamic "statement" {
    for_each = local.is_promoted ? [local.ecr_repo_source] : []
    content {
      sid       = "EcrPullFromSource"
      effect    = "Allow"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      resources = [statement.value]
    }
  }

  statement {
    sid       = "RegisterTaskDef"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = [local.task_definition_arn_pattern]

    condition {
      test     = "NumericLessThanEquals"
      variable = "ecs:task-cpu"
      values   = ["512"]
    }

    condition {
      test     = "NumericLessThanEquals"
      variable = "ecs:task-memory"
      values   = ["1024"]
    }
  }

  statement {
    sid       = "TagRegisteredTaskDef"
    effect    = "Allow"
    actions   = ["ecs:TagResource"]
    resources = [local.task_definition_arn_pattern]

    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterTaskDefinition"]
    }
  }

  statement {
    sid       = "DescribeTaskDef"
    effect    = "Allow"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"] # No resource-level support
  }

  statement {
    sid       = "DescribeOneService"
    effect    = "Allow"
    actions   = ["ecs:DescribeServices"]
    resources = [local.service_arn]
  }

  statement {
    sid       = "UpdateOneService"
    effect    = "Allow"
    actions   = ["ecs:UpdateService"]
    resources = [local.service_arn]

    condition {
      test     = "ArnLike"
      variable = "ecs:task-definition"
      values   = [local.task_definition_arn_pattern]
    }
  }

  # Metadata only (ADR 0006, G14): the preflight checks that the secret has a current version. The G1 guardrail
  # still denies reading or writing a value. The six "?" match the random suffix, so only this one secret matches.
  statement {
    sid       = "DescribeAppSecretMetadata"
    effect    = "Allow"
    actions   = ["secretsmanager:DescribeSecret"]
    resources = ["${local.svc_arn["secretsmanager"]}:secret:${local.resource_names.secret}-??????"]
  }

  statement {
    sid       = "PassTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.ecs_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
