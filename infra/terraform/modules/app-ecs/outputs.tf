output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "task_family" {
  description = "Task definition family."
  value       = aws_ecs_task_definition.app.family
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  description = "ECR repository URL (holds the account ID, so the root does not re-export it)."
  value       = aws_ecr_repository.app.repository_url
}

output "log_group_name" {
  description = "Application log group."
  value       = aws_cloudwatch_log_group.app.name
}

output "secret_name" {
  description = "Secrets Manager secret name."
  value       = aws_secretsmanager_secret.app.name
}

output "secret_arn" {
  description = "Secret ARN used in secrets[].valueFrom."
  value       = aws_secretsmanager_secret.app.arn
}

output "exec_role_name" {
  description = "Task execution role name."
  value       = aws_iam_role.exec.name
}

output "task_role_name" {
  description = "Task role name."
  value       = aws_iam_role.task.name
}

output "exec_role_arn" {
  description = "Task execution role ARN."
  value       = aws_iam_role.exec.arn
}

output "task_role_arn" {
  description = "Task role ARN."
  value       = aws_iam_role.task.arn
}

output "target_group_arn" {
  description = "Target group ARN."
  value       = aws_lb_target_group.app.arn
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}
