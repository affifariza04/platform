terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {}
}

provider "aws" {
  region = "ap-southeast-3" # Jakarta
  default_tags {
    tags = { project = "affifariza04", environment = "production", managed_by = "terraform" }
  }
}

locals {
  name = "affi-prod"
}

module "network" {
  source     = "../../modules/network"
  name       = local.name
  azs        = ["ap-southeast-3a", "ap-southeast-3b", "ap-southeast-3c"]
  nat_per_az = true # an AZ outage must not cut egress for the other two
}

module "cluster" {
  source              = "../../modules/cluster"
  name                = local.name
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.private_subnets
  node_instance_types = ["m6i.large", "m5.large"] # two types: more capacity pools
  node_min            = 3
  node_max            = 12
}

module "database" {
  source                     = "../../modules/database"
  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_group               = module.network.database_subnet_group
  allowed_security_group_ids = [module.cluster.node_security_group_id]
  instance_class             = "db.m6g.large"
  multi_az                   = true # synchronous standby in a second AZ
  deletion_protection        = true
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "database_endpoint" {
  value = module.database.endpoint
}
