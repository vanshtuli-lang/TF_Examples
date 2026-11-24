# Optional Application Load Balancer in front of the Airflow UI/API (port 8080).

resource "aws_lb" "airflow" {
  count = var.create_load_balancer ? 1 : 0

  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = var.alb_internal
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = var.alb_subnet_ids
  idle_timeout       = 120

  lifecycle {
    precondition {
      condition     = length(var.alb_subnet_ids) >= 2 && length(var.allowed_cidrs) > 0
      error_message = "With create_load_balancer = true, set alb_subnet_ids (2+ subnets in different AZs) and allowed_cidrs."
    }
  }
}

# The target reports unhealthy for the first ~10 minutes after launch, while
# the instance installs packages, pulls the image and migrates the database.
resource "aws_lb_target_group" "airflow" {
  count = var.create_load_balancer ? 1 : 0

  name     = "${var.name}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/api/v2/monitor/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_target_group_attachment" "airflow" {
  count = var.create_load_balancer ? 1 : 0

  target_group_arn = aws_lb_target_group.airflow[0].arn
  target_id        = aws_instance.airflow.id
  port             = 8080
}

# HTTP: forwards to Airflow, or redirects to HTTPS when a certificate is set.
resource "aws_lb_listener" "http" {
  count = var.create_load_balancer ? 1 : 0

  load_balancer_arn = aws_lb.airflow[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https ? "redirect" : "forward"
    target_group_arn = local.https ? null : aws_lb_target_group.airflow[0].arn

    dynamic "redirect" {
      for_each = local.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.create_load_balancer && local.https ? 1 : 0

  load_balancer_arn = aws_lb.airflow[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.airflow[0].arn
  }
}
