output "karpenter_helm_release" {
  description = "Karpenter Helm release name"
  value       = helm_release.karpenter.name
}

output "node_instance_profile_name" {
  description = "IAM instance profile name for Karpenter-managed nodes"
  value       = aws_iam_instance_profile.node.name
}
