terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # State lives in S3 with DynamoDB locking; bucket/table are passed at init:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = "ap-southeast-3" # Jakarta
  default_tags {
    tags = { project = "affifariza04", environment = "staging", managed_by = "terraform" }
  }
}

locals {
  name = "affi-staging"
}

module "network" {
  source     = "../../modules/network"
  name       = local.name
  azs        = ["ap-southeast-3a", "ap-southeast-3b", "ap-southeast-3c"]
  nat_per_az = false # one shared NAT: cheaper, acceptable for staging
}

module "cluster" {
  source     = "../../modules/cluster"
  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnets
  node_min   = 2
  node_max   = 4
}

module "database" {
  source                     = "../../modules/database"
  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_group               = module.network.database_subnet_group
  allowed_security_group_ids = [module.cluster.node_security_group_id]
  multi_az                   = false
  deletion_protection        = false # staging is disposable
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "database_endpoint" {
  value = module.database.endpoint
}
