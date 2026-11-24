output "airflow_url" {
  description = "Airflow UI and API through the load balancer. Use as api_base_url in airflow-podman and airflow_url in airflow-config."
  value       = local.base_url
}

output "instance_id" {
  value = aws_instance.airflow.id
}

output "instance_private_ip" {
  value = aws_instance.airflow.private_ip
}

output "connect_command" {
  description = "Open a shell on the instance (Session Manager)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.airflow.id}"
}

output "rds_endpoint" {
  value = aws_db_instance.airflow.address
}

output "sql_alchemy_conn" {
  description = "For airflow-podman: export TF_VAR_sql_alchemy_conn=\"$(terraform output -raw sql_alchemy_conn)\""
  value       = "postgresql+psycopg2://airflow:${random_password.db.result}@${aws_db_instance.airflow.address}:5432/airflow"
  sensitive   = true
}

output "airflow_podman_tfvars" {
  description = "Starting point for ../airflow-podman/terraform.tfvars."
  value       = <<-EOT
    hosts = {
      airflow = {
        address = "${aws_instance.airflow.private_ip}"
        # host_key = "ecdsa-sha2-nistp256 ..."   # /etc/ssh/ssh_host_ecdsa_key.pub on the instance
      }
    }
    ssh = {
      user             = "ec2-user"   # default login user on the RHEL 9 AMI
      private_key_path = "~/.ssh/${var.key_name}.pem"
    }
    api_base_url = "${local.base_url}"
    project_dir  = "../my-astro-project"
  EOT
}

output "efs_id" {
  value = aws_efs_file_system.airflow.id
}

output "alb_dns_name" {
  value = aws_lb.airflow.dns_name
}
