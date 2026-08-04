# Technical Task for OpsFleet

Terraform automation for an AWS EKS cluster with Karpenter-managed x86 and
Graviton node pools.

## Prerequisites

Install the local CLIs:

```bash
terraform version
aws --version
kubectl version --client
helm version
```

Configure AWS credentials before running the scripts. For a named AWS profile:

```bash
export AWS_PROFILE=<your-profile>
aws sts get-caller-identity
```

If your shell or CI already provides `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, and optionally `AWS_SESSION_TOKEN`, you do not need
`AWS_PROFILE`.

## Configure

Create the dev variables file:

```bash
cp terraform/environments/dev/terraform.tfvars.example terraform/environments/dev/terraform.tfvars
```

Review and edit:

```bash
terraform/environments/dev/terraform.tfvars
```

At minimum, confirm:

- `aws_region`
- `cluster_name`
- `public_access_cidrs`
- `access_entries`, if other IAM principals need cluster access

## Deploy From Scratch

Run from the repository root:

```bash
terraform/scripts/run.sh --apply
```

The script performs the full bootstrap and deploy flow:

1. Creates/updates the bootstrap backend resources: S3 state bucket and
   DynamoDB lock table.
2. Generates `terraform/environments/dev/backend.hcl` from bootstrap outputs
   if it does not already exist.
3. Applies VPC + EKS first, because Kubernetes/Helm providers need a live EKS
   API endpoint.
4. Applies Karpenter Helm release, EC2NodeClasses, and NodePools.
5. Adds/updates the local kubectl context named after the cluster, for example
   `opsfleet-dev`.

Approximate runtime: 15-20 minutes.

## Verify

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl get nodepools
kubectl get ec2nodeclasses
```

Example pods scheduled by Karpenter:

![Example pods scheduled on Karpenter nodes](terraform/examples/pods.jpeg)

Example nodes provisioned by Karpenter:

![Example Karpenter nodes](terraform/examples/nodes.jpeg)

## Destroy

Run from the repository root:

```bash
terraform/scripts/destroy.sh --apply
```

The script destroys in the safe order:

1. Deletes Karpenter Kubernetes resources directly while the EKS API is still
   available.
2. Removes the matching Helm/manifest resources from Terraform state after
   they are deleted.
3. Destroys the remaining dev AWS resources: Karpenter IAM, EKS, VPC, NAT,
   security groups, and related resources.
4. Removes the matching local kubectl context.
5. Destroys the bootstrap backend resources after dev state is empty.

## More Detail

See [terraform/README.md](terraform/README.md) for architecture notes,
provider ordering details, pod scheduling examples, and operational commands.
