# Input validation (B5).
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

run "rejects_short_account_id" {
  command = plan
  variables {
    aws_account_id = "12345678901"
  }
  expect_failures = [var.aws_account_id]
}

run "accepts_a_new_env_name" {
  command = plan

  variables {
    env = "qa"
  }
}

run "accepts_prod" {
  command = plan

  variables {
    env = "prod"
  }
}

run "rejects_env_uppercase" {
  command = plan

  variables {
    env = "Dev"
  }

  expect_failures = [var.env]
}

run "rejects_env_one_character" {
  command = plan

  variables {
    env = "a"
  }

  expect_failures = [var.env]
}

run "rejects_env_nine_characters" {
  command = plan

  variables {
    env = "toolongnm"
  }

  expect_failures = [var.env]
}

run "rejects_env_leading_digit" {
  command = plan

  variables {
    env = "9qa"
  }

  expect_failures = [var.env]
}

run "rejects_env_hyphen" {
  command = plan

  variables {
    env = "qa-x"
  }

  expect_failures = [var.env]
}

run "rejects_env_path" {
  command = plan

  variables {
    env = "../x"
  }

  expect_failures = [var.env]
}

run "rejects_bad_email" {
  command = plan
  variables {
    budget_email = "not-an-email"
  }
  expect_failures = [var.budget_email]
}

run "rejects_non_numeric_owner_id" {
  command = plan
  variables {
    github_owner_id = "abc"
  }
  expect_failures = [var.github_owner_id]
}

run "rejects_non_numeric_repo_id" {
  command = plan
  variables {
    github_repo_id = "12x"
  }
  expect_failures = [var.github_repo_id]
}
