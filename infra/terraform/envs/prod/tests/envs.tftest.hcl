# Every env root stays thin and consistent with bootstrap (ADR 0004, E16 to E18; ADR 0012). Offline: nothing talks
# to AWS. The same file runs in every envs/<env>/ (the parity guard keeps the copies identical, ADR 0008, P3): each
# expected name is built from var.env and var.prefix, which the committed terraform.tfvars sets. Only the account ID
# (never committed) is set here.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_ecr_image" {
    defaults = { image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }
}

variables {
  aws_account_id = "123456789012"
}

run "default_tags_match_bootstrap" {
  command = plan

  assert {
    condition = local.default_tags == {
      Project   = "ship-it-serverless"
      Env       = var.env
      ManagedBy = "terraform"
    }
    error_message = "default_tags must be identical to bootstrap (NFR-8)"
  }
}

run "env_equals_the_directory_name" {
  command = plan

  assert {
    condition     = var.env == basename(abspath(path.root))
    error_message = "terraform.tfvars env must equal the name of this directory, so the state key and the names cannot point at another environment"
  }
}

run "committed_tfvars_plan_this_envs_stack" {
  command = plan

  assert {
    condition = (
      module.app_lambda.function_name == "${var.prefix}-${var.env}-app"
      && module.app_lambda.alias_name == "live"
      && module.app_lambda.ecr_repository_name == "${var.prefix}-${var.env}-app"
      && module.app_lambda.secret_name == "${var.prefix}/${var.env}/app-api-key"
      && module.app_lambda.lambda_log_group_name == "/aws/lambda/${var.prefix}-${var.env}-app"
      && module.app_lambda.api_log_group_name == "/aws/apigateway/${var.prefix}-${var.env}-api"
      && module.app_lambda.exec_role_name == "${var.prefix}-${var.env}-app-exec"
    )
    error_message = "the committed tfvars must produce the bootstrap name contract for var.env"
  }

  # ADR 0012 L1, L2, L10 lab values.
  assert {
    condition = (
      var.memory_mb == 512
      && var.timeout_s == 10
      && var.log_retention_days == 7
      && var.api_throttle_rate_limit == 5
      && var.api_throttle_burst_limit == 10
    )
    error_message = "the committed tfvars carry the ADR 0012 lab values (512 MB, 10 s, 7 days, 5/s, burst 10)"
  }
}

# The alerts topic is bootstrap's (monitoring.tf): <prefix>-<env>-security-alerts in this account and region.
run "alarms_go_to_the_bootstrap_topic" {
  command = plan

  assert {
    condition     = local.alarm_topic_arn == "arn:aws:sns:${var.aws_region}:123456789012:${var.prefix}-${var.env}-security-alerts"
    error_message = "the alarm topic ARN must name the bootstrap security alerts topic of this env"
  }
}

# terraform test cannot enumerate `output`, so the declared names are read from outputs.tf and the values are pinned.
run "root_outputs_are_exactly_the_account_free_set" {
  command = plan

  assert {
    condition = (
      toset([for m in regexall("(?m)^output \"([a-z_]+)\"", file("outputs.tf")) : m[0]]) == toset([
        "function_name", "alias_name", "api_endpoint", "ecr_repository_name", "secret_name",
      ])
      && output.function_name != ""
    )
    error_message = "root outputs must be exactly this set; ARNs, the ECR URL and account IDs stay module outputs (public logs)"
  }

  assert {
    condition = (
      output.function_name == "${var.prefix}-${var.env}-app"
      && output.alias_name == "live"
      && output.ecr_repository_name == "${var.prefix}-${var.env}-app"
      && output.secret_name == "${var.prefix}/${var.env}/app-api-key"
    )
    error_message = "output values must be the plain names from the bootstrap contract"
  }
}

run "short_account_id_is_rejected" {
  command = plan

  variables {
    aws_account_id = "12345678901"
  }

  expect_failures = [var.aws_account_id]
}

run "reserved_concurrency_is_off_by_default" {
  command = plan

  assert {
    condition     = var.reserved_concurrency == null
    error_message = "reserved_concurrency stays unset in the committed tfvars (ADR 0012 L10, Finding 10)"
  }
}
