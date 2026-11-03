# The app image repository of this account's environment (ADR 0012 L4). It lives in bootstrap, not in envs/<env>:
# a Lambda image function can only be created from an image that already exists in a private repository of the
# same region (Finding 6), destroying an env must never delete the images its versions run, and promotion and
# rollback by digest keep working while the dev stack is down (closes ADR 0008 R22).

locals {
  # ADR 0012 L8: the deploy keeps the newest 10 published versions, ECR keeps 20 images, so no kept version points
  # at an expired image (Finding 7).
  ecr_keep_images = 20

  # Sensitive input, but whether it is set is not a secret; the dynamic statement below needs a plain bool.
  promotion_enabled = nonsensitive(var.promotion_target_account_id != null)
}

resource "aws_ecr_repository" "app" {
  name                 = local.resource_names.ecr_repository
  image_tag_mutability = "IMMUTABLE"
  # Bootstrap destroy only (account teardown); env destroys never touch this repository.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# One rule only. No "expire untagged" rule: an image pinned by digest may be untagged (ADR 0004, E10).
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${local.ecr_keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = local.ecr_keep_images
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "ecr_repository" {
  # Lambda pulls the image as the service principal (Finding 5). aws:sourceArn limits it to this env's function,
  # its versions and aliases (confused deputy protection). Lambda adds a statement like this itself only when the
  # caller holds ecr:SetRepositoryPolicy; no CI role does, so this statement is the only way in.
  statement {
    sid     = "LambdaPull"
    effect  = "Allow"
    actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values   = ["${local.svc_arn["lambda"]}:function:${local.resource_names.function}*"]
    }
  }

  # Pull-only access for the promoted environment's deploy role (ADR 0008 P9; moved here from the app module by
  # ADR 0012 L4). The principal is the target account, narrowed to the one role by aws:PrincipalArn, so the policy
  # is valid even before that role exists. That role's own identity policy (iam_deploy.tf EcrPullFromSource, in the
  # target account's bootstrap) must allow the same two actions on this repository, so both accounts agree.
  dynamic "statement" {
    for_each = local.promotion_enabled ? [var.promotion_target_account_id] : []
    content {
      sid     = "PromotionPull"
      effect  = "Allow"
      actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]

      principals {
        type        = "AWS"
        identifiers = ["arn:${local.partition}:iam::${statement.value}:root"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalArn"
        values   = ["arn:${local.partition}:iam::${statement.value}:role/${var.prefix}-${var.promotion_target_env}-gha-deploy"]
      }
    }
  }
}

# Only the admin who applies bootstrap may change this policy: no CI role holds ecr:SetRepositoryPolicy.
resource "aws_ecr_repository_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy     = data.aws_iam_policy_document.ecr_repository.json
}
