variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster (e.g. '1.30')"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the EKS cluster"
  type        = list(string)
}

variable "cluster_endpoint_public_access" {
  description = "Enable public access to the cluster API endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Enable private access to the cluster API endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public cluster API endpoint. Restrict to office/VPN ranges in real environments."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "authentication_mode" {
  description = "EKS cluster authentication mode. 'API' relies solely on EKS Access Entries (no aws-auth ConfigMap)."
  type        = string
  default     = "API"
}

variable "access_entries" {
  description = "EKS Access Entries granting IAM principals (users/roles) cluster access, keyed by an arbitrary map key. See terraform-aws-modules/eks access_entries schema."
  type        = any
  default     = {}
}

variable "cluster_enabled_log_types" {
  description = "EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_encryption_config" {
  description = "KMS encryption configuration for cluster secrets"
  type = object({
    provider_key_arn = optional(string)
    resources        = list(string)
  })
  default = {
    resources = ["secrets"]
  }
}

variable "cluster_addons" {
  description = "EKS addons to deploy"
  type = map(object({
    addon_version               = optional(string)
    configuration_values        = optional(string)
    resolve_conflicts_on_update = optional(string)
  }))
  default = {
    # addon_version omitted (null) -> module resolves the AWS-recommended
    # default version for the cluster's Kubernetes version. "latest" is not
    # a valid addon_version value and will fail the AWS API call.
    vpc-cni = {
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      resolve_conflicts_on_update = "OVERWRITE"
    }
    eks-pod-identity-agent = {
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
}

variable "tags" {
  description = "Additional tags for all EKS resources"
  type        = map(string)
  default     = {}
}
