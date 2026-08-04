# Karpenter module - installs Karpenter via Helm and creates
# NodePools for system, x86, and Graviton workloads.
#
# Architecture:
#   - system      (amd64, on-demand)  → critical infrastructure (CoreDNS, etc.)
#   - app-x86     (amd64, spot)       → general x86 applications
#   - app-graviton (arm64, spot)       → ARM-compatible (Graviton) applications
#
# NOTE: EC2NodeClass/NodePool CRDs are applied via the "kubectl_manifest"
# resource (gavinbunney/kubectl provider), not hashicorp/kubernetes'
# "kubernetes_manifest". kubernetes_manifest calls the cluster API during
# `terraform plan` (not just apply), so it breaks the very first plan/apply
# against a cluster that isn't reachable yet. kubectl_manifest defers the
# API call to apply time, which fits Karpenter's bootstrap ordering.

locals {
  karpenter_namespace = "kube-system"

  # NodePool names
  np_system       = "system"
  np_app_x86      = "app-x86"
  np_app_graviton = "app-graviton"

  # EC2NodeClass names
  ec2nc_x86   = "default-x86"
  ec2nc_arm64 = "default-arm64"
}

# -----------------------------------------------------------------------------
# Karpenter Helm Release
# -----------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = local.karpenter_namespace
  create_namespace = false # kube-system already exists
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version

  values = [
    yamlencode({
      serviceAccount = {
        name = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.irsa_role_arn
        }
      }
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = var.sqs_queue_name
      }
      # Karpenter will run on Fargate (bootstrap via fargate profile)
      tolerations = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NoSchedule"
        }
      ]
    })
  ]
}

# -----------------------------------------------------------------------------
# Node IAM Role for Karpenter-managed EC2 instances
# -----------------------------------------------------------------------------
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# Attach required policies for EKS worker nodes
resource "aws_iam_role_policy_attachment" "node_worker" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Grants the node role kubelet-node auth (equivalent of the old aws-auth
# ConfigMap mapping to system:bootstrappers/system:nodes) — without this,
# kubelet's node registration is rejected with "Unauthorized".
resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.node.name

  tags = var.tags
}

# -----------------------------------------------------------------------------
# EC2NodeClass: x86 (amd64)
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "ec2nodeclass_x86" {
  depends_on        = [helm_release.karpenter]
  server_side_apply = true

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = local.ec2nc_x86
    }
    spec = {
      amiFamily = "AL2023"
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      role = aws_iam_instance_profile.node.name
      tags = merge(var.tags, {
        "karpenter.sh/discovery" = var.cluster_name
      })
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]
    }
  })
}

# -----------------------------------------------------------------------------
# EC2NodeClass: arm64 (Graviton)
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "ec2nodeclass_arm64" {
  depends_on        = [helm_release.karpenter]
  server_side_apply = true

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = local.ec2nc_arm64
    }
    spec = {
      amiFamily = "AL2023"
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      role = aws_iam_instance_profile.node.name
      tags = merge(var.tags, {
        "karpenter.sh/discovery" = var.cluster_name
      })
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]
    }
  })
}

# -----------------------------------------------------------------------------
# NodePool: system (amd64, on-demand) — critical infrastructure
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "nodepool_system" {
  depends_on        = [kubectl_manifest.ec2nodeclass_x86]
  server_side_apply = true

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = local.np_system
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = local.ec2nc_x86
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = var.system_instance_families },
          ]
          # Taint system nodes so only pods with matching tolerations schedule here
          taints = [
            { key = "CriticalAddonsOnly", value = "true", effect = "NoSchedule" }
          ]
        }
      }
      limits = {
        cpu    = var.system_node_pool_limits.cpu
        memory = var.system_node_pool_limits.memory
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1h"
        budgets = [
          { nodes = "10%", schedule = "@daily", duration = "1h" }
        ]
      }
      weight = 100
    }
  })
}

# -----------------------------------------------------------------------------
# NodePool: app-x86 (amd64, spot with on-demand fallback)
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "nodepool_app_x86" {
  depends_on        = [kubectl_manifest.ec2nodeclass_x86]
  server_side_apply = true

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = local.np_app_x86
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = local.ec2nc_x86
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = var.app_x86_instance_families },
          ]
        }
      }
      limits = {
        cpu    = var.app_x86_node_pool_limits.cpu
        memory = var.app_x86_node_pool_limits.memory
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30m"
        budgets = [
          { nodes = "20%", schedule = "@daily", duration = "1h" }
        ]
      }
      weight = 50
    }
  })
}

# -----------------------------------------------------------------------------
# NodePool: app-graviton (arm64, spot with on-demand fallback)
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "nodepool_app_graviton" {
  depends_on        = [kubectl_manifest.ec2nodeclass_arm64]
  server_side_apply = true

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = local.np_app_graviton
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = local.ec2nc_arm64
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["arm64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = var.app_graviton_instance_families },
          ]
        }
      }
      limits = {
        cpu    = var.app_graviton_node_pool_limits.cpu
        memory = var.app_graviton_node_pool_limits.memory
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30m"
        budgets = [
          { nodes = "20%", schedule = "@daily", duration = "1h" }
        ]
      }
      weight = 50
    }
  })
}
