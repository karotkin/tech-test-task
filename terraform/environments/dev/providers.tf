# -----------------------------------------------------------------------------
# Terraform configuration
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  # S3 backend with state locking. Left empty on purpose: real values
  # (bucket/key/region/dynamodb_table or use_lockfile) live in a
  # gitignored backend.hcl, supplied at init time so no account-specific
  # config is tracked in this file. See backend.hcl.example and README.
  #
  # terraform init -backend-config=backend.hcl
  #
  # To use local state (for a quick test), run:
  # terraform init -backend=false
  backend "s3" {}
}

# -----------------------------------------------------------------------------
# AWS Provider
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# -----------------------------------------------------------------------------
# Kubernetes & Helm providers
# -----------------------------------------------------------------------------
# These providers reference the EKS module outputs, so they are configured
# after the cluster is created. For the first `terraform apply`, run:
#
#   terraform apply -target module.eks
#   terraform apply
#
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name,
      "--region",
      var.aws_region,
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        module.eks.cluster_name,
        "--region",
        var.aws_region,
      ]
    }
  }
}

# Used for Karpenter's EC2NodeClass/NodePool CRDs instead of the
# hashicorp/kubernetes "kubernetes_manifest" resource: kubernetes_manifest
# calls the cluster API during `plan` (not just apply), so a first-time
# deploy against a not-yet-created/reachable cluster fails the whole plan.
# kubectl_manifest defers that call to apply time.
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name,
      "--region",
      var.aws_region,
    ]
  }
}
