# Nothing here carries the account ID: apply logs are public (ADR 0004, E18). ARNs and the ECR URL stay module outputs.
output "alb_url" {
  description = "Public URL of the load balancer (plain HTTP)."
  value       = "http://${module.app_ecs.alb_dns_name}"
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = module.app_ecs.cluster_name
}

output "service_name" {
  description = "ECS service name."
  value       = module.app_ecs.service_name
}

output "task_family" {
  description = "Task definition family."
  value       = module.app_ecs.task_family
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = module.app_ecs.ecr_repository_name
}

output "log_group_name" {
  description = "Application log group."
  value       = module.app_ecs.log_group_name
}

output "secret_name" {
  description = "Secrets Manager secret name. Set its value by hand (put-secret-value)."
  value       = module.app_ecs.secret_name
}
