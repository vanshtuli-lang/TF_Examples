output "airflow_url" {
  description = "Where to open Airflow. Without a load balancer, run port_forward_command first."
  value       = local.airflow_url
}

output "user_password_commands" {
  description = "Per UI user, the command that prints their password. Run one with: $(terraform output -json user_password_commands | jq -r .admin)"
  value = {
    for u, p in aws_ssm_parameter.user_password : u => "aws ssm get-parameter --region ${var.aws_region} --name ${p.name} --with-decryption --query Parameter.Value --output text"
  }
}

output "connect_command" {
  description = "Open a shell on the instance (Session Manager, no SSH)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.airflow.id}"
}

output "port_forward_command" {
  description = "Forward localhost:8080 to the Airflow UI (Session Manager, no SSH or load balancer)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.airflow.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080"
}

output "load_balancer_dns_name" {
  description = "Point your hostname (CNAME) here."
  value       = var.create_load_balancer ? aws_lb.airflow[0].dns_name : null
}

output "instance_id" {
  value = aws_instance.airflow.id
}

output "rds_endpoint" {
  value = aws_db_instance.airflow.address
}

output "efs_id" {
  value = var.create_efs ? aws_efs_file_system.airflow[0].id : null
}
