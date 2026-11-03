# Execution role of the function (ADR 0012 L9). Not AWSLambdaBasicExecutionRole: that managed policy allows
# logs:CreateLogGroup on "*". The bootstrap boundary caps it, and the apply role can only create it with that
# boundary attached.

# Lambda only, with no condition. aws:SourceAccount and aws:SourceArn are not documented for the Lambda execution
# role trust (no official Lambda page found; community reports say they break role assumption). A key the service
# does not send fails closed, so the function could not assume its role at all: an outage, not a gain. The
# confused deputy case does not apply either: another account's function can only use this role if someone passes
# it, and iam:PassRole on this role belongs to the apply role of this account alone (bootstrap PassAppExecRole).
data "aws_iam_policy_document" "exec_trust" {
  statement {
    sid     = "LambdaAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "exec" {
  # The function's own log group only: the group ARN and its streams.
  statement {
    sid       = "LogsWriteOneGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [aws_cloudwatch_log_group.lambda.arn, "${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  # FR-8, L5: the one secret, by exact ARN. The AWS managed key needs no kms:Decrypt.
  # lambda:SourceFunctionArn: Lambda adds this key to AWS API requests made from inside the function's execution
  # environment, always as the unqualified function ARN, and it is valid in identity policies (ArnEquals). So the
  # read only works from this function, not from anyone else who obtains this role's credentials. The bootstrap
  # boundary carries the same condition. Source: Lambda Developer Guide, "Using source function ARN to control
  # function access behavior" (https://docs.aws.amazon.com/lambda/latest/dg/permissions-source-function-arn.html).
  statement {
    sid       = "ReadTheAppSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]

    condition {
      test     = "ArnEquals"
      variable = "lambda:SourceFunctionArn"
      values   = [local.function_arn]
    }
  }
}

resource "aws_iam_role" "exec" {
  name                 = local.names.app_exec_role
  assume_role_policy   = data.aws_iam_policy_document.exec_trust.json
  permissions_boundary = local.boundary_arn
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "exec" {
  name   = "exec"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}
