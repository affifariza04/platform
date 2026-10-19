terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 6
}

variable "public_endpoint_cidrs" {
  type        = list(string)
  description = "Who may reach the Kubernetes API. Keep this to office/VPN ranges; CI uses OIDC from inside AWS."
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.name
  cluster_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids # private subnets only: nodes get no public IPs

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.public_endpoint_cidrs

  # Secrets in etcd are envelope-encrypted with a dedicated KMS key.
  cluster_encryption_config = { resources = ["secrets"] }

  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true # pods get IAM roles, never node credentials

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    general = {
      instance_types = var.node_instance_types
      min_size       = var.node_min
      max_size       = var.node_max
      desired_size   = var.node_min
      # IMDSv2 only, one hop: pods can't borrow the node's instance credentials.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}
