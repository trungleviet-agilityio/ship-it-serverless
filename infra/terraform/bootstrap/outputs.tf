# Not sensitive: the user copies these into GitHub variables (NFR-1).
output "state_bucket_name" {
  description = "Terraform state bucket."
  value       = aws_s3_bucket.state.bucket
}

output "plan_role_arn" {
  description = "Role for pull_request plan jobs."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for apply jobs in this environment."
  value       = aws_iam_role.apply.arn
}

output "deploy_role_arn" {
  description = "Role for deploy jobs in this environment."
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "ecs_permissions_boundary_arn" {
  description = "Boundary that every ECS task and execution role must carry."
  value       = aws_iam_policy.ecs_boundary.arn
}

output "oidc_sub_prefix" {
  description = "Must equal sub_claim_prefix reported by the GitHub OIDC API."
  value       = local.gh_sub_prefix
}

output "aws_region" {
  description = "Region of every resource."
  value       = var.aws_region
}

output "resource_names" {
  description = "Name contract that envs/dev must follow (ADR 0002)."
  value       = local.resource_names
}

output "workflow_files" {
  description = "Workflow files the apply and deploy roles trust through job_workflow_ref. Each must exist under .github/workflows/."
  value       = local.workflow_files
}

output "security_alerts_topic_name" {
  description = "SNS topic that receives unexpected GitHub OIDC assumption alerts. Confirm the email subscription once."
  value       = aws_sns_topic.security_alerts.name
}

output "deploy_workflow_file" {
  description = "Workflow file the deploy role trusts (app-deploy.yml in the build env, app-promote.yml in a promoted env)."
  value       = local.workflow_files.deploy[0]
}
