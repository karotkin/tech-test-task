variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint URL"
  type        = string
}

variable "irsa_role_arn" {
  description = "IAM role ARN for Karpenter IRSA"
  type        = string
}

variable "sqs_queue_name" {
  description = "SQS queue name for Spot interruption handling"
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.3.0"
}

# -----------------------------------------------------------------------------
# System NodePool — critical infrastructure (on-demand, amd64)
# -----------------------------------------------------------------------------
variable "system_instance_families" {
  description = "Instance families for the system NodePool (on-demand only)"
  type        = list(string)
  default     = ["t3", "t3a", "c5", "m5"]
}

variable "system_node_pool_limits" {
  description = "Resource limits for the system NodePool"
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "10"
    memory = "40Gi"
  }
}

# -----------------------------------------------------------------------------
# App x86 NodePool — general applications (spot, amd64)
# -----------------------------------------------------------------------------
variable "app_x86_instance_families" {
  description = "Instance families for the x86 application NodePool (spot)"
  type        = list(string)
  default     = ["t3", "t3a", "c5", "c5a", "c6i", "m5", "m5a", "m6i", "r5", "r6i"]
}

variable "app_x86_node_pool_limits" {
  description = "Resource limits for the x86 app NodePool"
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "100"
    memory = "400Gi"
  }
}

# -----------------------------------------------------------------------------
# App Graviton NodePool — ARM-compatible applications (spot, arm64)
# -----------------------------------------------------------------------------
variable "app_graviton_instance_families" {
  description = "Instance families for the Graviton NodePool (spot)"
  type        = list(string)
  default     = ["t4g", "c7g", "m7g", "r7g", "c6g", "m6g", "r6g"]
}

variable "app_graviton_node_pool_limits" {
  description = "Resource limits for the Graviton app NodePool"
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "100"
    memory = "400Gi"
  }
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
