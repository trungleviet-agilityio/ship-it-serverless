resource "aws_ecr_repository" "app" {
  name                 = local.names.ecr_repository
  image_tag_mutability = "IMMUTABLE"
  # Removed with the stack: the lab is torn down after every session.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# One rule only. No "expire untagged" rule: buildx index children and attestations can be untagged, and
# expiring them could break an image pinned by digest (ADR 0004, E10).
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${var.ecr_keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_keep_images
      }
      action = { type = "expire" }
    }]
  })
}

# Pull-only access for the promoted environment's deploy role (ADR 0008 P9). The principal is the target account,
# narrowed to the one role by aws:PrincipalArn, so the policy is valid even before that role exists. That role's own
# identity policy (bootstrap EcrPullFromSource) must allow the same two actions on this repository.
locals {
  promotion_enabled = var.promotion_target_env != ""
  promotion_policy = local.promotion_enabled ? jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PromotionPullOnly"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${var.promotion_target_account_id}:root" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = {
        StringEquals = {
          "aws:PrincipalArn" = "arn:${local.partition}:iam::${var.promotion_target_account_id}:role/${var.prefix}-${var.promotion_target_env}-gha-deploy"
        }
      }
    }]
  }) : null
}

resource "aws_ecr_repository_policy" "promotion" {
  count = local.promotion_enabled ? 1 : 0

  repository = aws_ecr_repository.app.name
  policy     = local.promotion_policy
}
