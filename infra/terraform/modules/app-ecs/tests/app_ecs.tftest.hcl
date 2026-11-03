# What the module must create and must not allow (ADR 0004, E5 to E15). Offline: nothing talks to AWS.
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

# Computed attributes are unknown at plan time; pin the ones the assertions compare.
override_resource {
  override_during = plan
  target          = aws_secretsmanager_secret.app
  values          = { arn = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-AbCdEf" }
}
override_resource {
  override_during = plan
  target          = aws_ecr_repository.app
  values          = { arn = "arn:aws:ecr:ap-southeast-1:123456789012:repository/sis-dev-app" }
}
override_resource {
  override_during = plan
  target          = aws_cloudwatch_log_group.app
  values          = { arn = "arn:aws:logs:ap-southeast-1:123456789012:log-group:/ecs/sis-dev-app" }
}
override_resource {
  override_during = plan
  target          = aws_security_group.alb
  values          = { id = "sg-alb0000000000000" }
}
override_resource {
  override_during = plan
  target          = aws_security_group.task
  values          = { id = "sg-task000000000000" }
}
override_resource {
  override_during = plan
  target          = aws_subnet.public
  values          = { id = "subnet-0000000000000000" }
}
override_resource {
  override_during = plan
  target          = aws_iam_role.exec
  values          = { arn = "arn:aws:iam::123456789012:role/sis-dev-ecs-exec" }
}
override_resource {
  override_during = plan
  target          = aws_iam_role.task
  values          = { arn = "arn:aws:iam::123456789012:role/sis-dev-ecs-task" }
}
override_resource {
  override_during = plan
  target          = aws_lb_target_group.app
  values          = { arn = "arn:aws:elasticloadbalancing:ap-southeast-1:123456789012:targetgroup/sis-dev-tg/0123456789abcdef" }
}

variables {
  prefix          = "sis"
  env             = "dev"
  aws_region      = "ap-southeast-1"
  azs             = ["ap-southeast-1a", "ap-southeast-1b"]
  container_image = "public.ecr.aws/docker/library/python:3.13-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

run "names_follow_the_bootstrap_contract" {
  command = plan

  assert {
    condition = (
      aws_ecs_cluster.this.name == "sis-dev-cluster"
      && aws_ecs_service.app.name == "sis-dev-app"
      && aws_ecs_task_definition.app.family == "sis-dev-app"
      && aws_ecr_repository.app.name == "sis-dev-app"
      && aws_cloudwatch_log_group.app.name == "/ecs/sis-dev-app"
      && aws_lb.this.name == "sis-dev-alb"
      && aws_lb_target_group.app.name == "sis-dev-tg"
      && aws_iam_role.exec.name == "sis-dev-ecs-exec"
      && aws_iam_role.task.name == "sis-dev-ecs-task"
      && aws_secretsmanager_secret.app.name == "sis/dev/app-api-key"
    )
    error_message = "every name must equal the bootstrap resource_names contract"
  }
}

run "network_is_two_public_subnets_without_nat" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && aws_subnet.public[0].availability_zone == "ap-southeast-1a" && aws_subnet.public[1].availability_zone == "ap-southeast-1b"
    error_message = "two subnets, one per requested AZ"
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.40.0.0/24" && aws_subnet.public[1].cidr_block == "10.40.1.0/24"
    error_message = "subnets are /24 slices of the VPC CIDR"
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "ECS assigns the task IP; subnets must not map one on launch"
  }

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "VPC DNS support and hostnames must be on"
  }

  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0" && length(aws_route_table_association.public) == 2
    error_message = "one default route to the internet gateway and two associations"
  }
}

run "security_group_rules_are_standalone_and_narrow" {
  command = plan

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.alb_http) == 1
      && aws_vpc_security_group_ingress_rule.alb_http[0].from_port == 80
      && aws_vpc_security_group_ingress_rule.alb_http[0].to_port == 80
      && aws_vpc_security_group_ingress_rule.alb_http[0].ip_protocol == "tcp"
    )
    error_message = "ALB ingress is TCP 80 only, one rule per allowed CIDR"
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.alb_to_task.from_port == 8080
      && aws_vpc_security_group_egress_rule.alb_to_task.to_port == 8080
      && aws_vpc_security_group_egress_rule.alb_to_task.referenced_security_group_id == aws_security_group.task.id
    )
    error_message = "ALB egress is the container port to the task group only"
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.task_from_alb.from_port == 8080
      && aws_vpc_security_group_ingress_rule.task_from_alb.to_port == 8080
      && aws_vpc_security_group_ingress_rule.task_from_alb.referenced_security_group_id == aws_security_group.alb.id
      && aws_vpc_security_group_ingress_rule.task_from_alb.cidr_ipv4 == null
    )
    error_message = "task ingress is the container port from the ALB group only"
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.task_https.from_port == 443
      && aws_vpc_security_group_egress_rule.task_https.to_port == 443
      && aws_vpc_security_group_egress_rule.task_https.ip_protocol == "tcp"
    )
    error_message = "task egress is TCP 443 only"
  }
}

run "alb_ingress_follows_the_input" {
  command = plan

  variables {
    alb_ingress_cidrs = ["198.51.100.0/24", "203.0.113.0/24"]
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.alb_http) == 2
      && aws_vpc_security_group_ingress_rule.alb_http[0].cidr_ipv4 == "198.51.100.0/24"
      && aws_vpc_security_group_ingress_rule.alb_http[1].cidr_ipv4 == "203.0.113.0/24"
    )
    error_message = "one ALB ingress rule per allowed CIDR, indexed in input order"
  }

  # The CIDR may be a maintainer's address (a repository secret): it must not reach a description.
  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.alb_http : !strcontains(r.description, "198.51") && !strcontains(r.description, "203.0")
    ])
    error_message = "rule descriptions must not hold a CIDR"
  }
}

run "validation_rejects_an_ipv6_alb_cidr" {
  command = plan

  variables {
    alb_ingress_cidrs = ["::/0"]
  }

  expect_failures = [var.alb_ingress_cidrs]
}

run "validation_rejects_an_invalid_alb_cidr" {
  command = plan

  variables {
    alb_ingress_cidrs = ["not-a-cidr"]
  }

  expect_failures = [var.alb_ingress_cidrs]
}

run "alb_is_public_and_strict" {
  command = plan

  assert {
    condition     = aws_lb.this.internal == false && aws_lb.this.load_balancer_type == "application" && aws_lb.this.drop_invalid_header_fields
    error_message = "internet-facing application ALB that drops invalid headers"
  }

  assert {
    condition = (
      aws_lb_target_group.app.target_type == "ip"
      && aws_lb_target_group.app.port == 8080
      && aws_lb_target_group.app.health_check[0].path == "/health"
      && aws_lb_target_group.app.health_check[0].matcher == "200"
    )
    error_message = "ip target group on the container port probing /health for 200"
  }

  assert {
    condition     = aws_lb_listener.http.port == 80 && aws_lb_listener.http.protocol == "HTTP" && aws_lb_listener.http.default_action[0].type == "forward"
    error_message = "HTTP 80 listener forwards to the target group"
  }
}

run "ecr_is_immutable_scanned_and_has_one_lifecycle_rule" {
  command = plan

  assert {
    condition     = aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.app.image_scanning_configuration[0].scan_on_push && aws_ecr_repository.app.force_delete
    error_message = "immutable tags, scan on push, force delete for teardown"
  }

  assert {
    condition = (
      length(jsondecode(aws_ecr_lifecycle_policy.app.policy).rules) == 1
      && jsondecode(aws_ecr_lifecycle_policy.app.policy).rules[0].selection.tagStatus == "any"
      && jsondecode(aws_ecr_lifecycle_policy.app.policy).rules[0].selection.countType == "imageCountMoreThan"
      && jsondecode(aws_ecr_lifecycle_policy.app.policy).rules[0].selection.countNumber == 10
    )
    error_message = "exactly one lifecycle rule: tagStatus any, more than 10 images"
  }
}

run "logs_and_secret_shell" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.app.retention_in_days == 7
    error_message = "log retention is 7 days"
  }

  assert {
    condition     = aws_secretsmanager_secret.app.recovery_window_in_days == 0
    error_message = "secret is deleted at once so a re-create works (Q3)"
  }
}

run "roles_carry_the_boundary_and_trust_only_ecs_tasks" {
  command = plan

  assert {
    condition     = aws_iam_role.exec.permissions_boundary == "arn:aws:iam::123456789012:policy/sis-dev-ecs-boundary" && aws_iam_role.task.permissions_boundary == aws_iam_role.exec.permissions_boundary
    error_message = "both roles carry the bootstrap boundary"
  }

  assert {
    condition     = aws_iam_role.exec.max_session_duration == 3600 && aws_iam_role.task.max_session_duration == 3600
    error_message = "max_session_duration is 3600 (NFR-7)"
  }

  # Every role trust statement: exactly one principal, type Service, identifiers exactly ecs-tasks (ADR 0004 L-finding).
  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.exec_trust, data.aws_iam_policy_document.task_trust] :
      length(doc.statement) == 1
      && doc.statement[0].effect == "Allow"
      && length(doc.statement[0].principals) == 1
      && one(doc.statement[0].principals).type == "Service"
      && one(doc.statement[0].principals).identifiers == toset(["ecs-tasks.amazonaws.com"])
    ])
    error_message = "every role trust statement must be exactly type Service with identifiers [ecs-tasks.amazonaws.com]"
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.exec_trust.statement[0].condition) == 0
      && toset([for c in data.aws_iam_policy_document.task_trust.statement[0].condition : "${c.test}|${c.variable}"]) == toset(["StringEquals|aws:SourceAccount", "ArnLike|aws:SourceArn"])
    )
    error_message = "task role trust carries the SourceAccount and SourceArn conditions"
  }

  assert {
    condition = (
      toset(one([for c in data.aws_iam_policy_document.task_trust.statement[0].condition : c if c.variable == "aws:SourceAccount"]).values) == toset(["123456789012"])
      && toset(one([for c in data.aws_iam_policy_document.task_trust.statement[0].condition : c if c.variable == "aws:SourceArn"]).values) == toset(["arn:aws:ecs:ap-southeast-1:123456789012:*"])
    )
    error_message = "SourceAccount is the caller account and SourceArn is ECS in this region and account"
  }
}

run "exec_policy_is_scoped_to_one_secret_repo_and_log_group" {
  command = plan

  assert {
    condition = (
      toset(flatten([for s in data.aws_iam_policy_document.exec.statement : s.actions if s.sid == "ReadTheAppSecret"])) == toset(["secretsmanager:GetSecretValue"])
      && one([for s in data.aws_iam_policy_document.exec.statement : s.resources if s.sid == "ReadTheAppSecret"]) == toset(["arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-AbCdEf"])
    )
    error_message = "GetSecretValue on exactly the one secret ARN"
  }

  assert {
    condition = (
      one([for s in data.aws_iam_policy_document.exec.statement : s.resources if s.sid == "EcrPullOneRepository"]) == toset(["arn:aws:ecr:ap-southeast-1:123456789012:repository/sis-dev-app"])
      && one([for s in data.aws_iam_policy_document.exec.statement : s.resources if s.sid == "LogsWriteOneGroup"]) == toset(["arn:aws:logs:ap-southeast-1:123456789012:log-group:/ecs/sis-dev-app:*"])
    )
    error_message = "ECR pull on the one repository, log writes on the one group"
  }

  assert {
    condition = (
      toset(flatten([for s in data.aws_iam_policy_document.exec.statement : s.actions if contains(s.resources, "*")])) == toset(["ecr:GetAuthorizationToken"])
      && alltrue([for s in data.aws_iam_policy_document.exec.statement : s.effect == "Allow"])
    )
    error_message = "the only wildcard resource is ecr:GetAuthorizationToken, and every statement allows"
  }

  assert {
    condition     = alltrue([for s in data.aws_iam_policy_document.exec.statement : !anytrue([for a in s.actions : strcontains(a, "*")])])
    error_message = "no wildcard actions"
  }
}

run "task_definition_maps_the_secret_by_arn" {
  command = plan

  assert {
    condition = (
      aws_ecs_task_definition.app.cpu == "256"
      && aws_ecs_task_definition.app.memory == "512"
      && aws_ecs_task_definition.app.network_mode == "awsvpc"
      && contains(aws_ecs_task_definition.app.requires_compatibilities, "FARGATE")
      && aws_ecs_task_definition.app.runtime_platform[0].cpu_architecture == "X86_64"
      && aws_ecs_task_definition.app.runtime_platform[0].operating_system_family == "LINUX"
    )
    error_message = "FARGATE awsvpc, task-level cpu 256 and memory 512, X86_64 Linux"
  }

  assert {
    condition = (
      length(jsondecode(aws_ecs_task_definition.app.container_definitions)) == 1
      && jsondecode(aws_ecs_task_definition.app.container_definitions)[0].name == "app"
      && jsondecode(aws_ecs_task_definition.app.container_definitions)[0].user == "10001:10001"
      && jsondecode(aws_ecs_task_definition.app.container_definitions)[0].readonlyRootFilesystem == true
      && jsondecode(aws_ecs_task_definition.app.container_definitions)[0].portMappings[0].containerPort == 8080
      && jsondecode(aws_ecs_task_definition.app.container_definitions)[0].mountPoints[0].containerPath == "/tmp"
    )
    error_message = "one container 'app': port 8080, user 10001:10001, read-only root, /tmp mount"
  }

  assert {
    condition = (
      length(jsondecode(aws_ecs_task_definition.app.container_definitions)[0].secrets) == 1
      && jsondecode(aws_ecs_task_definition.app.container_definitions)[0].secrets[0].name == "APP_API_KEY"
      && jsondecode(aws_ecs_task_definition.app.container_definitions)[0].secrets[0].valueFrom == aws_secretsmanager_secret.app.arn
    )
    error_message = "secrets is exactly APP_API_KEY with valueFrom = the secret ARN"
  }

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.app.container_definitions)[0].environment : e.name], "APP_API_KEY")
    error_message = "the key must never be a plain environment entry"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.app.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/ecs/sis-dev-app"
    error_message = "awslogs writes to the module log group"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.app.container_definitions)[0]), "command")
    error_message = "no command key (the image decides what runs)"
  }

  assert {
    condition     = aws_ecs_task_definition.app.execution_role_arn == aws_iam_role.exec.arn && aws_ecs_task_definition.app.task_role_arn == aws_iam_role.task.arn
    error_message = "execution and task roles are wired"
  }
}

# Terraform owns the shape of the task definition and app-deploy swaps only the image (ADR 0005, F2). A command or an
# entrypoint here would make the deploy render fail, so the container must carry neither.
run "container_has_no_command_or_entrypoint" {
  command = plan

  assert {
    condition = (
      !contains(keys(jsondecode(aws_ecs_task_definition.app.container_definitions)[0]), "command")
      && !contains(keys(jsondecode(aws_ecs_task_definition.app.container_definitions)[0]), "entryPoint")
    )
    error_message = "the container definition has no command and no entryPoint"
  }
}

run "service_rolls_with_circuit_breaker_rollback" {
  command = plan

  assert {
    condition = (
      aws_ecs_service.app.launch_type == "FARGATE"
      && aws_ecs_service.app.desired_count == 1
      && aws_ecs_service.app.deployment_controller[0].type == "ECS"
      && aws_ecs_service.app.deployment_configuration[0].strategy == "ROLLING"
      && aws_ecs_service.app.deployment_circuit_breaker[0].enable
      && aws_ecs_service.app.deployment_circuit_breaker[0].rollback
      && aws_ecs_service.app.deployment_minimum_healthy_percent == 100
      && aws_ecs_service.app.deployment_maximum_percent == 200
      && aws_ecs_service.app.enable_execute_command == false
      && aws_ecs_service.app.wait_for_steady_state == false
    )
    error_message = "FR-15: ROLLING with circuit breaker and rollback, one task"
  }

  assert {
    condition = (
      aws_ecs_service.app.network_configuration[0].assign_public_ip == true
      && aws_ecs_service.app.network_configuration[0].subnets == toset(aws_subnet.public[*].id)
      && aws_ecs_service.app.network_configuration[0].security_groups == toset([aws_security_group.task.id])
    )
    error_message = "tasks run in the module subnets with the task security group only"
  }

  assert {
    condition = (
      length(aws_ecs_service.app.load_balancer) == 1
      && one(aws_ecs_service.app.load_balancer).container_name == "app"
      && one(aws_ecs_service.app.load_balancer).container_port == 8080
      && one(aws_ecs_service.app.load_balancer).target_group_arn == aws_lb_target_group.app.arn
    )
    error_message = "service registers container app on port 8080 with the module target group"
  }
}

run "validation_rejects_cpu_above_the_iam_cap" {
  command = plan

  variables {
    task_cpu = 1024
  }

  expect_failures = [var.task_cpu]
}

run "validation_rejects_memory_above_the_iam_cap" {
  command = plan

  variables {
    task_memory = 2048
  }

  expect_failures = [var.task_memory]
}

run "validation_rejects_one_az" {
  command = plan

  variables {
    azs = ["ap-southeast-1a"]
  }

  expect_failures = [var.azs]
}

run "validation_accepts_a_new_env_name" {
  command = plan

  variables {
    env = "qa"
  }
}

run "validation_accepts_prod" {
  command = plan

  variables {
    env = "prod"
  }
}

run "validation_rejects_env_uppercase" {
  command = plan

  variables {
    env = "Dev"
  }

  expect_failures = [var.env]
}

run "validation_rejects_env_one_character" {
  command = plan

  variables {
    env = "a"
  }

  expect_failures = [var.env]
}

run "validation_rejects_env_nine_characters" {
  command = plan

  variables {
    env = "toolongnm"
  }

  expect_failures = [var.env]
}

run "validation_rejects_env_leading_digit" {
  command = plan

  variables {
    env = "9qa"
  }

  expect_failures = [var.env]
}

run "validation_rejects_env_hyphen" {
  command = plan

  variables {
    env = "qa-x"
  }

  expect_failures = [var.env]
}

run "validation_rejects_env_path" {
  command = plan

  variables {
    env = "../x"
  }

  expect_failures = [var.env]
}

run "validation_rejects_an_image_without_a_digest" {
  command = plan

  variables {
    container_image = "public.ecr.aws/docker/library/python:3.13-slim"
  }

  expect_failures = [var.container_image]
}

run "validation_rejects_a_recovery_window_of_three_days" {
  command = plan

  variables {
    secret_recovery_window_days = 3
  }

  expect_failures = [var.secret_recovery_window_days]
}

# ADR 0008 P9: no repository policy unless a promotion target is set; then pull-only, one role in one account.
run "no_repository_policy_without_a_promotion_target" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository_policy.promotion) == 0
    error_message = "no promotion target means no repository policy"
  }
}

run "repository_policy_is_pull_only_for_the_target_deploy_role" {
  command = plan

  variables {
    promotion_target_env        = "prod"
    promotion_target_account_id = "222222222222"
  }

  assert {
    condition = jsondecode(aws_ecr_repository_policy.promotion[0].policy).Statement == [{
      Sid       = "PromotionPullOnly"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::222222222222:root" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = { StringEquals = { "aws:PrincipalArn" = "arn:aws:iam::222222222222:role/sis-prod-gha-deploy" } }
    }]
    error_message = "the repository policy must allow only the two pull actions to the target env's deploy role"
  }
}

run "validation_rejects_a_promotion_target_without_an_account" {
  command = plan

  variables {
    promotion_target_env = "prod"
  }

  expect_failures = [var.promotion_target_account_id]
}

run "an_account_without_a_promotion_target_creates_nothing" {
  command = plan

  variables {
    promotion_target_account_id = "222222222222"
  }

  assert {
    condition     = length(aws_ecr_repository_policy.promotion) == 0
    error_message = "the account alone must not create a repository policy"
  }
}
