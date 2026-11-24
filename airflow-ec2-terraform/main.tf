# Latest RHEL 9 from Red Hat. Its AppStream repo has podman; Docker CE also supports it.
data "aws_ami" "rhel9" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*"]
  }
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.rhel9[0].id
  https  = var.certificate_arn != null

  # The URL users open. Without a load balancer, that is a Session Manager
  # port forward to localhost:8080 (see the port_forward_command output).
  airflow_url = (
    var.hostname != null ? "${local.https ? "https" : "http"}://${var.hostname}" :
    var.create_load_balancer ? "${local.https ? "https" : "http"}://${aws_lb.airflow[0].dns_name}" :
    "http://localhost:8080"
  )

  # Secrets live in SSM Parameter Store, never in user data. The instance reads
  # every parameter under this path at boot and writes it to its env file, so
  # any extra secret Airflow setting (e.g. AIRFLOW_CONN_MY_DB) can be added here.
  ssm_env_path = "/${var.name}/env"

  secret_env = {
    AIRFLOW__DATABASE__SQL_ALCHEMY_CONN = "postgresql+psycopg2://airflow:${random_password.db.result}@${aws_db_instance.airflow.address}:5432/airflow"
    AIRFLOW__CORE__FERNET_KEY           = replace(replace(random_bytes.fernet.base64, "+", "-"), "/", "_")
    AIRFLOW__API_AUTH__JWT_SECRET       = random_password.jwt_secret.result
    AIRFLOW__API__SECRET_KEY            = random_password.api_secret_key.result
  }
}

# ---------------------------------------------------------------- secrets
# Generated once and kept in Terraform state, so use an encrypted, access-controlled
# state backend (see versions.tf).

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "random_password" "api_secret_key" {
  length  = 64
  special = false
}

# 32 random bytes, URL-safe base64: the format Airflow's Fernet key needs.
resource "random_bytes" "fernet" {
  length = 32
}

resource "aws_ssm_parameter" "env" {
  for_each = local.secret_env

  name  = "${local.ssm_env_path}/${each.key}"
  type  = "SecureString"
  value = each.value
}

resource "aws_ssm_parameter" "admin_password" {
  name  = "/${var.name}/admin-password"
  type  = "SecureString"
  value = random_password.admin.result
}
