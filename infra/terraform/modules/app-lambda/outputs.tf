output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.app.function_name
}

output "function_arn" {
  description = "Lambda function ARN (holds the account ID, so the root does not re-export it)."
  value       = aws_lambda_function.app.arn
}

output "alias_name" {
  description = "Alias the HTTP API invokes; App Deploy moves it."
  value       = aws_lambda_alias.live.name
}

output "api_id" {
  description = "HTTP API ID."
  value       = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  description = "Public HTTPS endpoint of the HTTP API ($default stage, so no stage path)."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "ecr_repository_name" {
  description = "ECR repository name (owned by bootstrap, ADR 0012 L4)."
  value       = local.names.ecr_repository
}

output "ecr_repository_url" {
  description = "ECR repository URL of the bootstrap repository (holds the account ID, so the root does not re-export it)."
  value       = local.ecr_repository_url
}

output "lambda_log_group_name" {
  description = "Function log group."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "api_log_group_name" {
  description = "HTTP API access log group."
  value       = aws_cloudwatch_log_group.api.name
}

output "secret_name" {
  description = "Secrets Manager secret name."
  value       = aws_secretsmanager_secret.app.name
}

output "secret_arn" {
  description = "Secret ARN the app reads (APP_API_KEY_SECRET_ARN)."
  value       = aws_secretsmanager_secret.app.arn
}

output "exec_role_arn" {
  description = "Execution role ARN."
  value       = aws_iam_role.exec.arn
}

output "exec_role_name" {
  description = "Execution role name."
  value       = aws_iam_role.exec.name
}
