# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version (e.g. 1.36)"
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.3.0"
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
}

variable "private_subnets" {
  description = "Private subnet CIDRs"
  type        = list(string)
}

variable "public_subnets" {
  description = "Public subnet CIDRs"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Cluster access
# -----------------------------------------------------------------------------
variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint. Restrict to office/VPN CIDRs — do not leave 0.0.0.0/0 in real environments."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "access_entries" {
  description = <<-EOT
    EKS Access Entries mapping IAM principals to cluster RBAC access, e.g.:
      developer = {
        principal_arn = "arn:aws:iam::<account_id>:role/developer-role"
        policy_associations = {
          view = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
            access_scope = { type = "namespace", namespaces = ["default"] }
          }
        }
      }
    See https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html
  EOT
  type        = any
  default     = {}
}

# -----------------------------------------------------------------------------
# Karpenter NodePools — instance families
# -----------------------------------------------------------------------------
variable "system_instance_families" {
  description = "Instance families for the system NodePool (on-demand)"
  type        = list(string)
  default     = ["t3", "t3a", "c5", "m5"]
}

variable "app_x86_instance_families" {
  description = "Instance families for x86 application NodePool (spot)"
  type        = list(string)
  default     = ["t3", "t3a", "c5", "c5a", "c6i", "m5", "m5a", "m6i", "r5", "r6i"]
}

variable "app_graviton_instance_families" {
  description = "Instance families for Graviton NodePool (spot)"
  type        = list(string)
  default     = ["t4g", "c7g", "m7g", "r7g", "c6g", "m6g", "r6g"]
}
