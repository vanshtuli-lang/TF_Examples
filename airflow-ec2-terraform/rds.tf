# PostgreSQL for the Airflow metadata database.

resource "aws_db_subnet_group" "airflow" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "airflow" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = "airflow"
  username = "airflow"
  password = random_password.db.result
  port     = 5432

  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.airflow.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = true
}
