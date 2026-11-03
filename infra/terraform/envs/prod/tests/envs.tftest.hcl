# Every env root stays thin and consistent with bootstrap (ADR 0004, E16 to E18). Offline: nothing talks to AWS.
# The same file runs in every envs/<env>/ (the parity guard keeps the copies identical, ADR 0008, P3): each expected
# name is built from var.env, which the committed terraform.tfvars sets. Only the account ID (never committed) is set here.
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
  aws_account_id = "123456789012"
  # Used only where terraform.tfvars sets promotion_target_env (dev); CI passes the real one.
  promotion_target_account_id = "222222222222"
}

run "default_tags_match_bootstrap" {
  command = plan

  assert {
    condition = local.default_tags == {
      Project   = "ship-it-safely"
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
    condition     = module.app_ecs.cluster_name == "${var.prefix}-${var.env}-cluster" && module.app_ecs.service_name == "${var.prefix}-${var.env}-app"
    error_message = "the committed tfvars must produce the bootstrap name contract for var.env"
  }

  assert {
    condition     = module.app_ecs.secret_name == "${var.prefix}/${var.env}/app-api-key"
    error_message = "secret shell name follows the contract"
  }
}

# terraform test cannot enumerate `output`, so the declared names are read from outputs.tf and the values are pinned.
run "root_outputs_are_exactly_the_account_free_set" {
  command = plan

  assert {
    condition = (
      toset([for m in regexall("(?m)^output \"([a-z_]+)\"", file("outputs.tf")) : m[0]]) == toset([
        "alb_url", "cluster_name", "service_name", "task_family", "ecr_repository_name", "log_group_name", "secret_name",
      ])
      && output.cluster_name != ""
    )
    error_message = "root outputs must be exactly this set; ARNs, the ECR URL and account IDs stay module outputs (public logs)"
  }

  assert {
    condition = (
      output.cluster_name == "${var.prefix}-${var.env}-cluster"
      && output.service_name == "${var.prefix}-${var.env}-app"
      && output.task_family == "${var.prefix}-${var.env}-app"
      && output.ecr_repository_name == "${var.prefix}-${var.env}-app"
      && output.log_group_name == "/ecs/sis-${var.env}-app"
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

run "alb_ingress_defaults_to_open" {
  command = plan

  variables {
    alb_ingress_cidrs_json = ""
  }

  assert {
    condition     = nonsensitive(local.alb_ingress_cidrs) == ["0.0.0.0/0"]
    error_message = "an empty secret must keep the ALB open"
  }
}

run "alb_ingress_reads_the_json_secret" {
  command = plan

  variables {
    alb_ingress_cidrs_json = "[\"198.51.100.7/32\"]"
  }

  assert {
    condition     = nonsensitive(local.alb_ingress_cidrs) == ["198.51.100.7/32"]
    error_message = "a JSON list must decode to the CIDR list"
  }
}

run "alb_ingress_rejects_non_json" {
  command = plan

  variables {
    alb_ingress_cidrs_json = "not json"
  }

  expect_failures = [var.alb_ingress_cidrs_json]
}

run "alb_ingress_rejects_ipv6" {
  command = plan

  variables {
    alb_ingress_cidrs_json = "[\"::/0\"]"
  }

  expect_failures = [var.alb_ingress_cidrs_json]
}
