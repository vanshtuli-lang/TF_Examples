# users -> ALB (80/443) -> EC2 (8080) -> RDS (5432)
#                          EC2 -> EFS (2049)
# No inbound SSH: shell access is through Session Manager.

resource "aws_security_group" "alb" {
  count = var.create_load_balancer ? 1 : 0

  name        = "${var.name}-alb"
  description = "Airflow load balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.name}-ec2"
  description = "Airflow EC2 instance"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.create_load_balancer ? [1] : []
    content {
      description     = "Airflow UI/API from the load balancer"
      from_port       = 8080
      to_port         = 8080
      protocol        = "tcp"
      security_groups = [aws_security_group.alb[0].id]
    }
  }

  # Outbound: package repos, container registry, AWS APIs (SSM), RDS, EFS.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "Airflow metadata database"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from the Airflow instance"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
}

resource "aws_security_group" "efs" {
  count = var.create_efs ? 1 : 0

  name        = "${var.name}-efs"
  description = "Airflow EFS"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from the Airflow instance"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
}
