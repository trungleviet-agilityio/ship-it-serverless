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

  # The app reads its API key itself with SigV4 (ADR 0012 L5), and only from inside the function: Lambda adds
  # lambda:SourceFunctionArn (always the unqualified function ARN) to AWS API requests made from the function's
  # execution environment, and the key works in identity policies and boundaries (ArnEquals). Source: Lambda
  # Developer Guide, "Using source function ARN to control function access behavior"
  # (https://docs.aws.amazon.com/lambda/latest/dg/permissions-source-function-arn.html).
  # What this does and does not stop:
  # - The CI roles cannot read a value directly: guardrail G1 denies GetSecretValue to all three.
  # - The apply role may change the execution role's trust (UpdateAssumeRolePolicy) or re-create the role with a
  #   foreign trust. Whoever then assumes it still cannot read the secret: a request from outside the function
  #   carries no lambda:SourceFunctionArn, so this statement does not match and the boundary denies.
  # - The deploy role can run new code as the execution role (UpdateFunctionCode, then invoke), and that code can
  #   read the secret. Accepted risk (ADR 0012 L9, R4): the deploy role is gated by the main-only OIDC trust, the
  #   GitHub environment approval and the pinned workflow file (job_workflow_ref).
  statement {
    sid       = "AppSecretRead"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_pattern]

    condition {
      test     = "ArnEquals"
      variable = "lambda:SourceFunctionArn"
      values   = [local.function_arn_app]
    }
  }
}

resource "aws_iam_policy" "app_boundary" {
  name        = local.resource_names.boundary
  description = "Permissions boundary required on the Lambda function execution role"
  policy      = data.aws_iam_policy_document.app_boundary.json
}
