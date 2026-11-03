locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  name       = "${var.prefix}-${var.env}"

  # Name contract with bootstrap `resource_names` (ADR 0002): the apply and deploy roles are scoped by these.
  names = {
    cluster        = "${local.name}-cluster"
    service        = "${local.name}-app"
    task_family    = "${local.name}-app"
    ecr_repository = "${local.name}-app"
    log_group      = "/ecs/${local.name}-app"
    alb            = "${local.name}-alb"
    target_group   = "${local.name}-tg"
    exec_role      = "${local.name}-ecs-exec"
    task_role      = "${local.name}-ecs-task"
    secret         = "${var.prefix}/${var.env}/app-api-key"
    boundary       = "${local.name}-ecs-boundary"
  }

  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.names.boundary}"

  container_name = "app"
}
