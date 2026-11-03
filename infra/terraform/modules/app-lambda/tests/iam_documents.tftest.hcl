# The execution role and its inline policy carry the documents built for them, and those documents grant exactly
# what ADR 0012 L9 lists (least privilege). Policy attributes are unknown at plan with a mock provider, so this file
# applies against the mock: still offline. It also proves that a later image digest does not revert what App Deploy
# set (ignore_changes on image_uri and IMAGE_DIGEST, L3).
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

override_data {
  target = data.aws_ecr_image.app
  values = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
}

# Distinct JSON per document so a role wired to the wrong one is caught.
override_data {
  target = data.aws_iam_policy_document.exec_trust
  values = { json = "{\"doc\":\"exec_trust\"}" }
}
override_data {
  target = data.aws_iam_policy_document.exec
  values = { json = "{\"doc\":\"exec_policy\"}" }
}

# Generated ARNs from the mock are not valid ARNs; the provider validates them on apply.
override_resource {
  target = aws_iam_role.exec
  values = {
    id  = "sis-dev-app-exec"
    arn = "arn:aws:iam::123456789012:role/sis-dev-app-exec"
  }
}
override_resource {
  target = aws_secretsmanager_secret.app
  values = { arn = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-AbCdEf" }
}
override_resource {
  target = aws_cloudwatch_log_group.lambda
  values = { arn = "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-app" }
}
override_resource {
  target = aws_cloudwatch_log_group.api
  values = { arn = "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/apigateway/sis-dev-api" }
}
override_resource {
  target = aws_lambda_function.app
  values = {
    arn     = "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app"
    version = "1"
  }
}
override_resource {
  target = aws_lambda_alias.live
  values = { arn = "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app:live" }
}
override_resource {
  target = aws_apigatewayv2_api.this
  values = {
    id            = "abc123defg"
    execution_arn = "arn:aws:execute-api:ap-southeast-1:123456789012:abc123defg"
  }
}

variables {
  prefix     = "sis"
  env        = "dev"
  aws_region = "ap-southeast-1"
}

run "role_uses_the_rendered_documents" {
  command = apply

  assert {
    condition     = aws_iam_role.exec.assume_role_policy == data.aws_iam_policy_document.exec_trust.json && aws_iam_role.exec.assume_role_policy == "{\"doc\":\"exec_trust\"}"
    error_message = "the execution role trust must be the exec_trust document"
  }

  assert {
    condition = (
      aws_iam_role_policy.exec.policy == data.aws_iam_policy_document.exec.json
      && aws_iam_role_policy.exec.policy == "{\"doc\":\"exec_policy\"}"
      && aws_iam_role_policy.exec.role == aws_iam_role.exec.id
    )
    error_message = "the inline policy must be the exec document, on the execution role"
  }
}

run "trust_is_lambda_in_this_account" {
  command = apply

  assert {
    condition = [
      for s in data.aws_iam_policy_document.exec_trust.statement : [
        s.effect,
        toset(s.actions),
        toset(flatten([for p in s.principals : p.type])),
        toset(flatten([for p in s.principals : p.identifiers])),
        [for c in s.condition : [c.test, c.variable, toset(c.values)]],
      ]
      ] == [[
        "Allow",
        toset(["sts:AssumeRole"]),
        toset(["Service"]),
        toset(["lambda.amazonaws.com"]),
        [["StringEquals", "aws:SourceAccount", toset(["123456789012"])]],
    ]]
    error_message = "only lambda.amazonaws.com may assume the role, on behalf of this account (aws:SourceAccount)"
  }
}

run "exec_policy_is_least_privilege" {
  command = apply

  assert {
    condition = {
      for s in data.aws_iam_policy_document.exec.statement : s.sid => [s.effect, toset(s.actions), toset(s.resources)]
      } == {
      LogsWriteOneGroup = ["Allow", toset(["logs:CreateLogStream", "logs:PutLogEvents"]), toset([
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-app",
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-app:*",
      ])]
      ReadTheAppSecret = ["Allow", toset(["secretsmanager:GetSecretValue"]), toset([
        "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-AbCdEf",
      ])]
    }
    error_message = "the execution role may write to its own log group and read its one secret, nothing else"
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.exec.statement : [for r in s.resources : !strcontains(r, "*") || endswith(r, "/aws/lambda/sis-dev-app:*")]
    ]))
    error_message = "no wildcard resource beyond the log streams of the function's own group"
  }
}

# L3: a newer image in ECR (pushed by App Deploy) must not make Terraform swap the image or reset IMAGE_DIGEST.
run "later_digest_is_ignored" {
  command = plan

  override_data {
    target = data.aws_ecr_image.app
    values = { image_digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
  }

  assert {
    condition = (
      endswith(aws_lambda_function.app.image_uri, "@sha256:1111111111111111111111111111111111111111111111111111111111111111")
      && one(aws_lambda_function.app.environment).variables["IMAGE_DIGEST"] == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    )
    error_message = "image_uri and IMAGE_DIGEST keep the deployed values (ignore_changes)"
  }

  assert {
    condition     = aws_lambda_alias.live.function_version == "1"
    error_message = "the alias keeps the version App Deploy set (ignore_changes)"
  }
}

# The other variables are still Terraform's: a new memory size is planned even with the map-key ignore.
run "other_settings_still_apply" {
  command = plan

  variables {
    memory_mb = 1024
  }

  override_data {
    target = data.aws_ecr_image.app
    values = { image_digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
  }

  assert {
    condition = (
      aws_lambda_function.app.memory_size == 1024
      && one(aws_lambda_function.app.environment).variables["IMAGE_DIGEST"] == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
      && one(aws_lambda_function.app.environment).variables["AWS_LWA_PORT"] == "8080"
    )
    error_message = "memory changes are planned while IMAGE_DIGEST stays the deployed value"
  }
}
