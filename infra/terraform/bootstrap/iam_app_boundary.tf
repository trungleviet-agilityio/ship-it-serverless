# Permissions boundary for the function execution role (ADR 0012 L9, B15). Owned by bootstrap, so no GitHub role
# can edit it (G4), and the apply role can only create or change a role that carries it (IamAppRoleBounded).
# The execution role's own inline policy is narrower (one log group, one secret ARN); the boundary is the ceiling
# that holds even if that policy were widened by a bad apply.
# No ECR pull here: Lambda pulls the image as the service principal through the repository policy (ecr.tf,
# LambdaPull), not with the execution role.
data "aws_iam_policy_document" "app_boundary" {
  statement {
    sid     = "LambdaLogsWrite"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "${local.svc_arn["logs"]}:log-group:/aws/lambda/${local.name}-*",
      "${local.svc_arn["logs"]}:log-group:/aws/lambda/${local.name}-*:*",
    ]
  }

  # The app reads its API key itself with SigV4 (ADR 0012 L5). The CI roles never can (guardrail G1).
  statement {
    sid       = "AppSecretRead"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_pattern]
  }
}

resource "aws_iam_policy" "app_boundary" {
  name        = local.resource_names.boundary
  description = "Permissions boundary required on the Lambda function execution role"
  policy      = data.aws_iam_policy_document.app_boundary.json
}
