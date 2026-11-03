# Groups carry no inline rules. Rules are standalone resources so provider default_tags reach them, which the
# apply role needs to change or delete them (ADR 0004, E8).
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB: HTTP in, container port out to the tasks"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-alb" }
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Tasks: container port from the ALB, HTTPS out"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-task" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  # Indexed, not keyed by CIDR, and no CIDR in the description: the list can come from a masked CI secret, and
  # for_each keys and descriptions print in plan output (ADR 0007 S35). The length is not secret.
  count = nonsensitive(length(var.alb_ingress_cidrs))

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from allowed CIDR ${count.index}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = var.alb_ingress_cidrs[count.index]
}

resource "aws_vpc_security_group_egress_rule" "alb_to_task" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Container port to the tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.task.id
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "Container port from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

# Image pull, Secrets Manager and CloudWatch Logs are all HTTPS; DNS is not filtered by security groups.
resource "aws_vpc_security_group_egress_rule" "task_https" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS for image pull, secrets and logs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
