module "app_ecs" {
  source = "../../modules/app-ecs"

  prefix                      = var.prefix
  env                         = var.env
  aws_region                  = var.aws_region
  azs                         = var.azs
  vpc_cidr                    = var.vpc_cidr
  container_image             = var.container_image
  desired_count               = var.desired_count
  task_cpu                    = var.task_cpu
  task_memory                 = var.task_memory
  log_retention_days          = var.log_retention_days
  secret_recovery_window_days = var.secret_recovery_window_days
  alb_ingress_cidrs           = local.alb_ingress_cidrs
  promotion_target_env        = var.promotion_target_env
  promotion_target_account_id = var.promotion_target_account_id
}
