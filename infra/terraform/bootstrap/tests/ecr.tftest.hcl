# The app image repository and its policy (ADR 0012 L4, ADR 0008 P9). Offline: nothing talks to AWS.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

variables {
  # The fixture names use the prefix sis, whatever project.env holds (a fork).
  prefix          = "sis"
  aws_account_id  = "123456789012"
  github_owner_id = "111"
  github_repo_id  = "222"
  budget_email    = "ops@example.com"
}

run "repository_settings" {
  command = plan

  assert {
    condition = (
      aws_ecr_repository.app.name == "sis-dev-app"
      && aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE"
      && aws_ecr_repository.app.force_delete == true
      && one(aws_ecr_repository.app.image_scanning_configuration).scan_on_push == true
      && one(aws_ecr_repository.app.encryption_configuration).encryption_type == "AES256"
    )
    error_message = "sis-dev-app: immutable tags, scan on push, force_delete, AES256"
  }

  assert {
    condition = (
      one(jsondecode(aws_ecr_lifecycle_policy.app.policy).rules).selection == {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      && one(jsondecode(aws_ecr_lifecycle_policy.app.policy).rules).action == { type = "expire" }
    )
    error_message = "one lifecycle rule keeps the last 20 images (deploy keeps 10 versions, ADR 0012 L8)"
  }

  assert {
    condition     = aws_ecr_repository_policy.app.repository == aws_ecr_repository.app.name
    error_message = "the repository policy belongs to the app repository"
  }
}

run "lambda_pull_is_scoped_to_the_function" {
  command = plan

  assert {
    condition = [
      for s in data.aws_iam_policy_document.ecr_repository.statement : [
        s.effect,
        toset(s.actions),
        toset(flatten([for p in s.principals : p.identifiers])),
        toset(flatten([for p in s.principals : p.type])),
      ] if s.sid == "LambdaPull"
      ] == [[
        "Allow",
        toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]),
        toset(["lambda.amazonaws.com"]),
        toset(["Service"]),
    ]]
    error_message = "LambdaPull lets only the Lambda service pull, with the two pull actions"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.ecr_repository.statement : (
        length(s.condition) == 1
        && anytrue([
          for c in s.condition : (
            c.test == "StringLike"
            && c.variable == "aws:sourceArn"
            && toset(c.values) == toset(["arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app*"])
          )
        ])
      ) if s.sid == "LambdaPull"
    ])
    error_message = "LambdaPull needs StringLike aws:sourceArn on this env's function (confused deputy protection)"
  }

  assert {
    condition     = toset([for s in data.aws_iam_policy_document.ecr_repository.statement : s.sid]) == toset(["LambdaPull"])
    error_message = "without a promotion target the policy holds LambdaPull only"
  }
}

run "promotion_pull_with_a_target_account" {
  command = plan

  variables {
    promotion_target_account_id = "222222222222"
  }

  assert {
    condition     = toset([for s in data.aws_iam_policy_document.ecr_repository.statement : s.sid]) == toset(["LambdaPull", "PromotionPull"])
    error_message = "a promotion target adds exactly one PromotionPull statement"
  }

  assert {
    condition = nonsensitive([
      for s in data.aws_iam_policy_document.ecr_repository.statement : [
        s.effect,
        toset(s.actions),
        toset(flatten([for p in s.principals : p.identifiers if p.type == "AWS"])),
        [for c in s.condition : [c.test, c.variable, toset(c.values)]],
      ] if s.sid == "PromotionPull"
      ] == [[
        "Allow",
        toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]),
        toset(["arn:aws:iam::222222222222:root"]),
        [["StringEquals", "aws:PrincipalArn", toset(["arn:aws:iam::222222222222:role/sis-prod-gha-deploy"])]],
    ]])
    error_message = "PromotionPull: the target account root, narrowed to <prefix>-prod-gha-deploy, pull actions only"
  }
}

run "promotion_target_env_names_the_role" {
  command = plan

  variables {
    promotion_target_account_id = "222222222222"
    promotion_target_env        = "stage"
  }

  assert {
    condition = nonsensitive(anytrue(flatten([
      for s in data.aws_iam_policy_document.ecr_repository.statement : [
        for c in s.condition : contains(c.values, "arn:aws:iam::222222222222:role/sis-stage-gha-deploy")
      ] if s.sid == "PromotionPull"
    ])))
    error_message = "promotion_target_env names the target deploy role"
  }
}

run "rejects_a_short_promotion_target_account" {
  command = plan

  variables {
    promotion_target_account_id = "22222222222"
  }

  expect_failures = [var.promotion_target_account_id]
}
