# One EC2 instance. At first boot, user data installs the container runtime,
# mounts EFS, reads secrets from SSM, pulls the image and starts Airflow as
# systemd services. No SSH is needed; use Session Manager for a shell.

resource "aws_iam_role" "ec2" {
  name = "${var.name}-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Session Manager (shell and port forwarding).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Pull from ECR, if airflow_image is there.
resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Read this environment's secrets, and nothing else in Parameter Store.
resource "aws_iam_role_policy" "read_secrets" {
  name = "read-airflow-secrets"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.name}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "airflow" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.key_name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh.tftpl", {
    region         = var.aws_region
    runtime        = var.container_runtime
    image          = var.airflow_image
    efs_dns        = var.create_efs ? "${aws_efs_file_system.airflow[0].id}.efs.${var.aws_region}.amazonaws.com" : ""
    ssm_env_path   = local.ssm_env_path
    ssm_users_path = local.ssm_users_path
    airflow_run    = file("${path.module}/files/airflow-run.sh")
    airflow_env = merge(
      {
        AIRFLOW__CORE__EXECUTOR                           = "LocalExecutor"
        AIRFLOW__CORE__LOAD_EXAMPLES                      = "False"
        AIRFLOW__CORE__EXECUTION_API_SERVER_URL           = "http://127.0.0.1:8080/execution/"
        AIRFLOW__CORE__AUTH_MANAGER                       = "airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager"
        AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_USERS          = join(",", [for u in sort(keys(var.users)) : "${u}:${var.users[u]}"])
        AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_PASSWORDS_FILE = "/usr/local/airflow/config/passwords.json"
        AIRFLOW__API__BASE_URL                            = local.airflow_url
      },
      var.airflow_env,
    )
  }))

  tags = {
    Name = var.name
  }

  # Re-running terraform apply never replaces this instance on its own: a new
  # RHEL release or an edit to user data / airflow_image is ignored. To roll out
  # such a change, replace it on purpose (state is on RDS and EFS):
  #   terraform apply -replace=aws_instance.airflow
  lifecycle {
    ignore_changes = [ami, user_data, user_data_base64]
  }

  depends_on = [aws_efs_mount_target.airflow, aws_ssm_parameter.env, aws_ssm_parameter.user_password]
}
