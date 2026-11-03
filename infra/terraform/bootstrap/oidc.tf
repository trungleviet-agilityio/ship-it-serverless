# No thumbprint_list: AWS validates GitHub's TLS chain against its own trusted CAs (B11).
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# One trust policy per role (B13): StringEquals except the plan role's pull request merge ref, immutable IDs,
# ref pinned on every role, and the workflow file path (job_workflow_ref) on apply and deploy.
data "aws_iam_policy_document" "trust" {
  for_each = local.trust

  statement {
    sid     = "GitHubOidc"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [each.value.sub]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [var.github_repo_id]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_owner_id"
      values   = [var.github_owner_id]
    }

    condition {
      test     = each.value.ref_test
      variable = "${local.oidc_host}:ref"
      values   = [each.value.ref]
    }

    # The alert rule only sees this region's events. aws:RequestedRegion is always in the request context, and calls
    # to the global STS endpoint carry us-east-1, so those are refused too. An unexpected success can then only
    # happen in the alerted region (ADR 0007 fix round 1).
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }

    dynamic "condition" {
      for_each = each.value.workflows == null ? [] : [each.value.workflows]

      content {
        test     = "StringEquals"
        variable = "${local.oidc_host}:job_workflow_ref"
        values   = condition.value
      }
    }
  }
}
