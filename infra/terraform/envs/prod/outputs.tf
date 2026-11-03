# Nothing here carries the account ID: apply logs are public (ADR 0004, E18). ARNs and the ECR URL stay module outputs.
output "function_name" {
  description = "Lambda function name."
  value       = module.app_lambda.function_name
}

output "alias_name" {
  description = "Alias the HTTP API invokes; App Deploy moves it."
  value       = module.app_lambda.alias_name
}

output "api_endpoint" {
  description = "Public HTTPS endpoint of the HTTP API (no account ID in it)."
  value       = module.app_lambda.api_endpoint
}

# The repository name, not its URL: the URL holds the account ID (tf/policy.sh rule 8).
output "ecr_repository_name" {
  description = "ECR repository App Deploy pushes to (owned by bootstrap, ADR 0012 L4)."
  value       = module.app_lambda.ecr_repository_name
}

output "secret_name" {
  description = "Secrets Manager secret name. Set its value by hand (put-secret-value)."
  value       = module.app_lambda.secret_name
}
