# Permissions boundary for the ECS task and execution roles (B15). Owned by bootstrap, so no GitHub role
# can edit it (G4).
data "aws_iam_policy_document" "ecs_boundary" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # No resource-level support
  }

  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [local.ecr_repo_pattern]
  }

  statement {
    sid       = "LogsWrite"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.svc_arn["logs"]}:log-group:/ecs/${local.name}-*:*"]
  }

  statement {
    sid       = "AppSecretRead"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_pattern]
  }
}

resource "aws_iam_policy" "ecs_boundary" {
  name        = local.resource_names.boundary
  description = "Permissions boundary required on every ECS task and execution role"
  policy      = data.aws_iam_policy_document.ecs_boundary.json
}
