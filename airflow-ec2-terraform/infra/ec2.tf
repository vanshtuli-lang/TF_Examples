# Single EC2 instance (RHEL 9) for Astro Runtime (Chainguard) on Podman. User data
# only installs Podman and mounts EFS; ../airflow-podman installs Airflow over SSH.
# Interactive shell access is also available through Session Manager.

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

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  key_name = var.key_name

  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh.tftpl", {
    efs_id = aws_efs_file_system.airflow.id
    region = var.aws_region
  }))
  user_data_replace_on_change = true

  tags = {
    Name = var.name
  }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_efs_mount_target.airflow]
}
