terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "name" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type        = list(string)
  description = "Three AZs: the cluster and database spread across all of them."
}

variable "nat_per_az" {
  type        = bool
  default     = false
  description = "One NAT gateway per AZ (prod: survives an AZ outage) vs a single shared one (staging: cheaper)."
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  private_subnets  = [for i in range(3) : cidrsubnet(var.cidr, 4, i)]
  public_subnets   = [for i in range(3) : cidrsubnet(var.cidr, 8, 48 + i)]
  database_subnets = [for i in range(3) : cidrsubnet(var.cidr, 8, 64 + i)]

  enable_nat_gateway     = true
  single_nat_gateway     = !var.nat_per_az
  one_nat_gateway_per_az = var.nat_per_az
  enable_dns_hostnames   = true

  create_database_subnet_group       = true
  create_database_subnet_route_table = true # databases get no internet route at all

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 30

  # Tags the AWS Load Balancer Controller uses to discover subnets.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "database_subnet_group" {
  value = module.vpc.database_subnet_group_name
}
