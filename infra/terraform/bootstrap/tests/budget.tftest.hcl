# Budget alert (B21).
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

run "monthly_cost_budget" {
  command = plan

  assert {
    condition = (
      aws_budgets_budget.monthly.name == "sis-dev-monthly-cost"
      && aws_budgets_budget.monthly.budget_type == "COST"
      && aws_budgets_budget.monthly.limit_amount == "20"
      && aws_budgets_budget.monthly.limit_unit == "USD"
      && aws_budgets_budget.monthly.time_unit == "MONTHLY"
    )
    error_message = "budget must be 20 USD monthly COST"
  }

  assert {
    condition = (
      one(aws_budgets_budget.monthly.notification).comparison_operator == "GREATER_THAN"
      && one(aws_budgets_budget.monthly.notification).threshold == 80
      && one(aws_budgets_budget.monthly.notification).threshold_type == "PERCENTAGE"
      && one(aws_budgets_budget.monthly.notification).notification_type == "ACTUAL"
      && one(aws_budgets_budget.monthly.notification).subscriber_email_addresses == toset(["ops@example.com"])
    )
    error_message = "one ACTUAL 80 percent notification to budget_email"
  }
}
