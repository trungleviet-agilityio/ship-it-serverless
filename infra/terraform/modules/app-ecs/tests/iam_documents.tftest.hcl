# Each role and the inline policy must carry the document built for it, not another one (ADR 0004, E7 to E9).
# Policy attributes are unknown at plan with a mock provider, so this file applies against the mock: still offline.
# It is separate from app_ecs.tftest.hcl because that file's overrides are plan-only.
mock_provider "aws" {
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

# Distinct JSON per document so a role wired to the wrong one is caught.
override_data {
  target = data.aws_iam_policy_document.exec_trust
  values = { json = "{\"doc\":\"exec_trust\"}" }
}
override_data {
  target = data.aws_iam_policy_document.task_trust
  values = { json = "{\"doc\":\"task_trust\"}" }
}
override_data {
  target = data.aws_iam_policy_document.exec
  values = { json = "{\"doc\":\"exec_policy\"}" }
}

# Generated ARNs from the mock are not valid ARNs; the provider validates them on apply.
override_resource {
  target = aws_lb.this
  values = { arn = "arn:aws:elasticloadbalancing:ap-southeast-1:123456789012:loadbalancer/app/sis-dev-alb/0123456789abcdef" }
}
override_resource {
  target = aws_lb_target_group.app
  values = { arn = "arn:aws:elasticloadbalancing:ap-southeast-1:123456789012:targetgroup/sis-dev-tg/0123456789abcdef" }
}
override_resource {
  target = aws_iam_role.exec
  values = {
    id  = "sis-dev-ecs-exec"
    arn = "arn:aws:iam::123456789012:role/sis-dev-ecs-exec"
  }
}
override_resource {
  target = aws_iam_role.task
  values = {
    id  = "sis-dev-ecs-task"
    arn = "arn:aws:iam::123456789012:role/sis-dev-ecs-task"
  }
}

variables {
  prefix          = "sis"
  env             = "dev"
  aws_region      = "ap-southeast-1"
  azs             = ["ap-southeast-1a", "ap-southeast-1b"]
  container_image = "public.ecr.aws/docker/library/python:3.13-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

run "roles_use_the_rendered_documents" {
  command = apply

  assert {
    condition     = aws_iam_role.exec.assume_role_policy == data.aws_iam_policy_document.exec_trust.json && aws_iam_role.exec.assume_role_policy == "{\"doc\":\"exec_trust\"}"
    error_message = "the exec role trust must be the exec_trust document"
  }

  assert {
    condition     = aws_iam_role.task.assume_role_policy == data.aws_iam_policy_document.task_trust.json && aws_iam_role.task.assume_role_policy == "{\"doc\":\"task_trust\"}"
    error_message = "the task role trust must be the task_trust document"
  }

  assert {
    condition     = aws_iam_role_policy.exec.policy == data.aws_iam_policy_document.exec.json && aws_iam_role_policy.exec.policy == "{\"doc\":\"exec_policy\"}"
    error_message = "the exec inline policy must be the exec document"
  }

  assert {
    condition     = aws_iam_role_policy.exec.role == aws_iam_role.exec.id && aws_iam_role_policy.exec.role != aws_iam_role.task.id
    error_message = "the exec inline policy must be attached to the exec role, not the task role"
  }
}
