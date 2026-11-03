resource "aws_lb" "this" {
  name               = local.names.alb
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
  # Off on purpose: the lab is torn down after every session (ADR 0004, E9).
  enable_deletion_protection = false

  tags = { Name = local.names.alb }
}

resource "aws_lb_target_group" "app" {
  name                 = local.names.target_group
  vpc_id               = aws_vpc.this.id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = var.container_port
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = local.names.target_group }
}

# HTTPS is out of scope for the lab (PLAN section 2, ADR 0004 R6).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
