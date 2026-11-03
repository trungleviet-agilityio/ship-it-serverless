resource "aws_ecs_cluster" "this" {
  name = local.names.cluster

  setting {
    name  = "containerInsights"
    value = "disabled" # cost
  }
}

# cpu and memory are task level on purpose: the apply role's ecs:task-cpu and ecs:task-memory keys read them.
resource "aws_ecs_task_definition" "app" {
  family                   = local.names.task_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([{
    name                   = local.container_name
    image                  = var.container_image
    essential              = true
    user                   = "10001:10001"
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = var.container_port, protocol = "tcp" }]
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    environment            = [{ name = "APP_ENV", value = var.env }]
    # valueFrom is the secret ARN. The value is injected at container start (FR-8).
    secrets = [{ name = "APP_API_KEY", valueFrom = aws_secretsmanager_secret.app.arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = local.names.service
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"
  desired_count   = var.desired_count

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30
  availability_zone_rebalancing      = "ENABLED" # the AWS default, written to avoid drift
  enable_execute_command             = false
  # The first deployment cannot become stable before the secret has a value (ADR 0004, Finding 4).
  wait_for_steady_state = false

  deployment_controller {
    type = "ECS"
  }

  deployment_configuration {
    strategy = "ROLLING"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # The listener must exist before the target group is attached; the role policy must outlive the service so
  # deletion does not hang in DRAINING (provider docs).
  depends_on = [aws_lb_listener.http, aws_iam_role_policy.exec]

  lifecycle {
    # Phase 4 deploys register new revisions through the deploy role; do not revert them (ADR 0002).
    ignore_changes = [task_definition]
  }
}
