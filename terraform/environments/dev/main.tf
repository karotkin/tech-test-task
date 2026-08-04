# Root module for the "dev" environment (region set via var.aws_region)
#
# Composition:
#   1. VPC   → networking layer
#   2. EKS   → cluster + OIDC + Karpenter IAM
#   3. Karpenter → autoscaler + NodePools

locals {
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = "tech-test-task"
  }
}

# =============================================================================
# VPC
# =============================================================================
module "vpc" {
  source = "../../modules/vpc"

  name               = var.cluster_name
  cidr               = var.vpc_cidr
  availability_zones = var.availability_zones
  private_subnets    = var.private_subnets
  public_subnets     = var.public_subnets
  cluster_name       = var.cluster_name

  enable_nat_gateway     = true
  single_nat_gateway     = true # cost-saving for POC
  one_nat_gateway_per_az = false

  tags = local.common_tags
}

# =============================================================================
# EKS Cluster
# =============================================================================
module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs
  cluster_endpoint_private_access      = true

  access_entries = var.access_entries

  tags = local.common_tags
}

# =============================================================================
# Karpenter
# =============================================================================
module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name     = module.eks.cluster_name
  cluster_endpoint = module.eks.cluster_endpoint
  irsa_role_arn    = module.eks.karpenter_irsa_role_arn
  sqs_queue_name   = module.eks.karpenter_sqs_queue_name

  karpenter_version = var.karpenter_version

  # Customize instance families per environment
  system_instance_families       = var.system_instance_families
  app_x86_instance_families      = var.app_x86_instance_families
  app_graviton_instance_families = var.app_graviton_instance_families

  tags = local.common_tags
}
