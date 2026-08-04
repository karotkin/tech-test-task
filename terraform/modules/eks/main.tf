# EKS module - creates the EKS cluster without managed node groups
# (Karpenter handles all node provisioning).
#
# Also creates the OIDC provider and IAM role required by Karpenter.

locals {
  cluster_name = var.cluster_name

  # Karpenter IRSA: https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/
  karpenter_namespace            = "kube-system"
  karpenter_service_account_name = "karpenter"
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access      = var.cluster_endpoint_private_access

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Access Entries replace the deprecated aws-auth ConfigMap: cluster access
  # for humans/CI is granted here as code, not by hand-editing a ConfigMap.
  authentication_mode                      = var.authentication_mode
  enable_cluster_creator_admin_permissions = true
  access_entries                           = var.access_entries

  # No managed node groups — Karpenter provisions all nodes
  create_node_security_group    = true
  create_cluster_security_group = true

  # Control plane logging
  cluster_enabled_log_types = var.cluster_enabled_log_types

  # OIDC provider (needed for IRSA)
  enable_irsa = true

  # IAM
  create_iam_role = true
  iam_role_name   = "${var.cluster_name}-cluster"

  # KMS encryption
  cluster_encryption_config = var.cluster_encryption_config

  # Tags
  tags = merge(
    var.tags,
    {
      "karpenter.sh/discovery" = var.cluster_name
    }
  )

  # Fargate profile for kube-system to bootstrap Karpenter
  # (solves chicken-and-egg: Karpenter needs a node to run, but nodes come from Karpenter)
  fargate_profiles = {
    karpenter = {
      name = "karpenter"
      selectors = [
        { namespace = local.karpenter_namespace }
      ]
      subnet_ids              = var.private_subnet_ids
      pod_execution_role_name = "${var.cluster_name}-fargate"
    }
    coredns = {
      name = "coredns"
      selectors = [
        { namespace = "kube-system", labels = { "k8s-app" = "kube-dns" } }
      ]
      subnet_ids              = var.private_subnet_ids
      pod_execution_role_name = "${var.cluster_name}-fargate"
    }
  }

  # EKS addons
  cluster_addons = var.cluster_addons
}

# -----------------------------------------------------------------------------
# Karpenter IAM Role (IRSA)
# -----------------------------------------------------------------------------
# Karpenter controller needs permissions for EC2, pricing, IAM, etc.
data "aws_iam_policy_document" "karpenter_controller" {
  # EC2 fleet/instance/launch-template lifecycle actions. AWS does not support
  # resource-level ARNs for RunInstances/CreateFleet targets (AMI, subnet, SG
  # are cross-account/shared), so these stay resource "*" per AWS's own
  # Karpenter IAM guidance. For stricter prod hardening, mirror the full
  # tag-conditioned policy from https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/#3-create-the-eks-cluster
  statement {
    sid = "KarpenterEC2Actions"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstances",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowPassingInstanceRole"
    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Karpenter v1 "role mode": EC2NodeClass.spec.role names an IAM role, and
  # Karpenter itself creates/manages the instance profile backing it (rather
  # than the caller pre-creating one), so it needs full instance-profile CRUD.
  statement {
    sid = "AllowInstanceProfileActions"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowSSMReadActions"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:*::parameter/aws/service/*"]
  }

  statement {
    sid = "AllowInterruptionQueueActions"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.karpenter.arn]
  }

  statement {
    sid       = "AllowClusterDiscovery"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller"
  description = "IAM policy for Karpenter controller"
  policy      = data.aws_iam_policy_document.karpenter_controller.json

  tags = var.tags
}

module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-karpenter"

  attach_karpenter_controller_policy = false

  role_policy_arns = {
    karpenter_controller = aws_iam_policy.karpenter_controller.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.karpenter_namespace}:${local.karpenter_service_account_name}"]
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# SQS Queue for Spot Interruption Handling
# -----------------------------------------------------------------------------
# Karpenter can react to Spot interruption notices via SQS
resource "aws_sqs_queue" "karpenter" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  kms_master_key_id         = null # use default AWS managed KMS key

  tags = var.tags
}

# SQS policy to allow AWS services to send spot interruption events
resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2SpotInterruption"
        Effect = "Allow"
        Principal = {
          Service = ["events.amazonaws.com", "sqs.amazonaws.com"]
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.karpenter.arn
      }
    ]
  })
}

# EventBridge rule to forward Spot interruption notices to SQS
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-spot-interruption"
  description = "Forward EC2 Spot interruption warnings to Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter.arn
}

# Instance Rebalance Recommendation
resource "aws_cloudwatch_event_rule" "instance_rebalance" {
  name        = "${var.cluster_name}-instance-rebalance"
  description = "Forward EC2 Instance Rebalance Recommendation to Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "instance_rebalance" {
  rule = aws_cloudwatch_event_rule.instance_rebalance.name
  arn  = aws_sqs_queue.karpenter.arn
}
