resource "aws_iam_role" "plan" {
  name                 = local.role_names.plan
  description          = "GitHub Actions pull_request plan (read only)"
  path                 = "/"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
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
    sid       = "StateRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.state_arn]
  }

  statement {
    sid       = "StateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.lock_arn]
  }

  # ReadOnlyAccess grants s3:Get* on every bucket in the account; this closes it to the two state keys.
  statement {
    sid           = "DenyS3ReadsOutsideState"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = [local.state_arn, local.lock_arn]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "state-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}
