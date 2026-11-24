variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources. Lowercase letters, digits, hyphens; max 24 chars."
  type        = string
  default     = "airflow-dev"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- network

variable "vpc_id" {
  description = "Existing VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "At least 2 private subnets in different AZs. The instance goes in the first; RDS and EFS use all of them."
  type        = list(string)
}

# ---------------------------------------------------------------- EC2

variable "ami_id" {
  description = "Optional AMI ID. Unset = latest RHEL 9 (x86_64). Must be dnf-based (RHEL 9 or Amazon Linux 2023). Amazon Linux 2023 only works with container_runtime = \"docker\": it has no podman package."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type. With LocalExecutor, tasks run on this VM."
  type        = string
  default     = "m7i.xlarge"
}

variable "root_volume_size_gb" {
  description = "Root disk size. Holds the container image (and /opt/airflow when create_efs = false)."
  type        = number
  default     = 100
}

variable "key_name" {
  description = "Optional EC2 key pair. Not needed: shell access is through Session Manager, and no SSH port is opened."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- Airflow

variable "airflow_image" {
  description = "Airflow image the instance pulls at boot. Prefer your scanned copy in an internal registry, pinned by digest (image@sha256:...)."
  type        = string
  default     = "quay.io/astronomer/astro-runtime:3.4-1-chainguard"
}

variable "container_runtime" {
  description = "podman or docker. Both run the same containers under the same systemd units."
  type        = string
  default     = "podman"

  validation {
    condition     = contains(["podman", "docker"], var.container_runtime)
    error_message = "container_runtime must be podman or docker."
  }
}

variable "airflow_env" {
  description = "Extra non-secret Airflow settings, e.g. { AIRFLOW__CORE__PARALLELISM = \"32\" }. For secrets, add an SSM parameter instead (see README)."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.airflow_env : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !strcontains(v, "\n")])
    error_message = "airflow_env keys must be environment variable names, and values can't contain newlines."
  }
}

# ---------------------------------------------------------------- optional pieces

variable "create_efs" {
  description = "Mount an EFS file system at /opt/airflow (DAGs, logs) so they survive instance replacement. false = root disk."
  type        = bool
  default     = true
}

variable "create_load_balancer" {
  description = "Put an Application Load Balancer in front of the Airflow UI. false = reach it with Session Manager port forwarding."
  type        = bool
  default     = true
}

variable "alb_subnet_ids" {
  description = "With create_load_balancer: at least 2 subnets in different AZs for the load balancer."
  type        = list(string)
  default     = []
}

variable "alb_internal" {
  description = "true = internal load balancer, reachable only from your network."
  type        = bool
  default     = true
}

variable "allowed_cidrs" {
  description = "With create_load_balancer: CIDRs allowed to open the Airflow UI."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "Optional ACM certificate ARN. Set it to serve HTTPS on 443 (80 redirects to 443)."
  type        = string
  default     = null
}

variable "hostname" {
  description = "Optional DNS name users open, e.g. airflow-dev.example.com (a CNAME to the load balancer you create). Used for Airflow's base_url."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- RDS

variable "db_engine_version" {
  description = "PostgreSQL major version (Airflow 3.4 supports 14-18)."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage_gb" {
  description = "RDS storage in GB."
  type        = number
  default     = 50
}

variable "db_deletion_protection" {
  description = "Block deletion of the database. Set to false (and apply) before terraform destroy."
  type        = bool
  default     = true
}
