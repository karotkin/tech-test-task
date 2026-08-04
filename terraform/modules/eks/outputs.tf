output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster certificate authority data (base64)"
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA"
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "cluster_security_group_id" {
  description = "Cluster security group ID"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Node security group ID"
  value       = module.eks.node_security_group_id
}

output "karpenter_irsa_role_arn" {
  description = "IAM role ARN for Karpenter controller (IRSA)"
  value       = module.karpenter_irsa.iam_role_arn
}

output "karpenter_sqs_queue_url" {
  description = "SQS queue URL for Spot interruption handling"
  value       = aws_sqs_queue.karpenter.url
}

output "karpenter_sqs_queue_name" {
  description = "SQS queue name for Spot interruption handling (Karpenter's settings.interruptionQueue expects a name, not an ARN)"
  value       = aws_sqs_queue.karpenter.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.eks.cluster_arn
}

output "karpenter_sqs_queue_arn" {
  description = "SQS queue ARN for Spot interruption handling"
  value       = aws_sqs_queue.karpenter.arn
}
