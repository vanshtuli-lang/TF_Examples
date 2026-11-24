# Optional EFS at /opt/airflow on the instance: DAGs and task logs survive
# when the instance is replaced.

resource "aws_efs_file_system" "airflow" {
  count = var.create_efs ? 1 : 0

  creation_token  = var.name
  encrypted       = true
  throughput_mode = "elastic"

  tags = {
    Name = var.name
  }
}

resource "aws_efs_mount_target" "airflow" {
  for_each = var.create_efs ? toset(var.private_subnet_ids) : toset([])

  file_system_id  = aws_efs_file_system.airflow[0].id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs[0].id]
}
