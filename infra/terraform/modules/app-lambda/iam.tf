# Execution role of the function (ADR 0012 L9). Not AWSLambdaBasicExecutionRole: that managed policy allows
# logs:CreateLogGroup on "*". The bootstrap boundary caps it, and the apply role can only create it with that
# boundary attached.

# Lambda only, and only on behalf of this account (confused deputy protection).
data "aws_iam_policy_document" "exec_trust" {
  statement {
    sid     = "LambdaAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
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
  statement {
    sid       = "ReadTheAppSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
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
