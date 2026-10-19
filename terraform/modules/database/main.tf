terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_group" {
  type = string
}

variable "allowed_security_group_ids" {
  type        = list(string)
  description = "Only these security groups (the EKS nodes) may connect on 5432."
}

variable "instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = true
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  vpc_id      = var.vpc_id
  description = "Postgres for ${var.name}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_cluster" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Postgres from cluster nodes"
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg16-"
  family      = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500" # log queries slower than 500 ms
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier_prefix = "${var.name}-"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = var.instance_class

  allocated_storage     = 20
  max_allocated_storage = 200 # storage autoscaling
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "app"
  username = "app_admin"
  # The password is generated and rotated by AWS in Secrets Manager:
  # it never appears in Terraform state, code, or CI logs.
  manage_master_user_password = true

  db_subnet_group_name   = var.subnet_group
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false

  multi_az                              = var.multi_az
  backup_retention_period               = 14
  copy_tags_to_snapshot                 = true
  deletion_protection                   = var.deletion_protection
  skip_final_snapshot                   = false
  final_snapshot_identifier             = "${var.name}-final"
  performance_insights_enabled          = true
  iam_database_authentication_enabled   = true
  auto_minor_version_upgrade            = true
  enabled_cloudwatch_logs_exports       = ["postgresql"]
  apply_immediately                     = false
  performance_insights_retention_period = 7
}

output "endpoint" {
  value = aws_db_instance.this.endpoint
}

output "master_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}
