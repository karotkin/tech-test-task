#!/usr/bin/env bash
# Tears down what run.sh creates, stage by stage, in REVERSE order
# (environments/dev -> bootstrap).
#
# Order matters here more than in run.sh: dev's state lives in the S3
# bucket + DynamoDB table that bootstrap creates. Destroying bootstrap
# first would delete the backend out from under dev's still-live
# resources (orphaned VPC/EKS, lost state, no way to clean up through
# terraform afterwards). So this script always destroys dev first, and
# refuses to destroy bootstrap while dev's remote state still lists any
# resources.
#
# Applies always use saved plan files. That keeps `destroy.sh --apply` non-
# interactive while still showing the exact plan immediately before apply.
#
# Usage:
#   terraform/scripts/destroy.sh                 # all stages, destroy plan only (dev, then bootstrap)
#   terraform/scripts/destroy.sh dev              # single stage, destroy plan only
#   terraform/scripts/destroy.sh --apply          # all stages, destroy plan + apply, dev then bootstrap
#   terraform/scripts/destroy.sh --apply dev      # destroy dev only
#   terraform/scripts/destroy.sh --apply bootstrap  # destroy bootstrap only (blocked if dev state non-empty)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP_DIR="${TF_ROOT}/bootstrap"
DEV_DIR="${TF_ROOT}/environments/dev"

# Same stage list/order as run.sh; this script walks it in reverse.
# "name|dir|description|extra init args|pre-destroy cleanup"
STAGES=(
  "bootstrap|${BOOTSTRAP_DIR}|Remote state backend: S3 bucket + DynamoDB lock table||"
  "dev|${DEV_DIR}|Environment dev: VPC + EKS + Karpenter|-backend-config=backend.hcl|karpenter"
)

APPLY=false
ONLY_STAGE=""
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    *) ONLY_STAGE="$arg" ;;
  esac
done

# Refuses to destroy bootstrap while dev's remote state still has
# resources in it — that would delete the S3 bucket/DynamoDB table out
# from under a live dev deployment, orphaning it with no way to clean up
# through terraform afterwards.
guard_bootstrap_destroy() {
  if [[ ! -f "${DEV_DIR}/backend.hcl" ]]; then
    return 0
  fi

  local count
  count="$(terraform -chdir="$DEV_DIR" state list 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -gt 0 ]]; then
    echo "error: refusing to destroy bootstrap — environments/dev still has ${count} resource(s) in state." >&2
    echo "       destroy dev first: terraform/scripts/destroy.sh --apply dev" >&2
    exit 1
  fi
}

state_has_address_prefix() {
  local prefix="$1"

  terraform state list 2>/dev/null | while IFS= read -r address; do
    if [[ "$address" == "$prefix"* ]]; then
      echo "yes"
      return 0
    fi
  done | grep -q '^yes$'
}

state_has_address() {
  local address="$1"

  terraform state list 2>/dev/null | while IFS= read -r existing; do
    if [[ "$existing" == "$address" ]]; then
      echo "yes"
      return 0
    fi
  done | grep -q '^yes$'
}

state_rm_existing() {
  local existing=()
  local address

  for address in "$@"; do
    if state_has_address "$address"; then
      existing+=("$address")
    fi
  done

  if [[ "${#existing[@]}" -eq 0 ]]; then
    return 0
  fi

  echo
  echo "--- terraform state rm (already deleted Kubernetes/Helm resources) ---"
  terraform state rm "${existing[@]}"
}

cleanup_karpenter_kubernetes() {
  local cluster_name region kubeconfig cluster_state

  if ! state_has_address "module.karpenter.helm_release.karpenter" && \
     ! state_has_address_prefix "module.karpenter.kubectl_manifest."; then
    echo
    echo "note: Karpenter Kubernetes resources already absent from state."
    return 0
  fi

  cluster_name="$(terraform output -raw cluster_name 2>/dev/null || true)"
  region="$(terraform output -raw aws_region 2>/dev/null || true)"

  if [[ -z "$cluster_name" || -z "$region" ]]; then
    cluster_state="$(terraform state show -no-color 'module.eks.module.eks.aws_eks_cluster.this[0]' 2>/dev/null || true)"
    if [[ -z "$cluster_name" ]]; then
      cluster_name="$(awk '$1 == "id" && $2 == "=" { gsub("\"", "", $3); print $3; exit }' <<< "$cluster_state")"
    fi
    if [[ -z "$region" ]]; then
      region="$(awk '$1 == "arn" && $2 == "=" { gsub("\"", "", $3); split($3, parts, ":"); print parts[4]; exit }' <<< "$cluster_state")"
    fi
  fi

  if [[ -z "$cluster_name" && -f terraform.tfvars ]]; then
    cluster_name="$(awk -F= '$1 ~ /^[[:space:]]*cluster_name[[:space:]]*$/ { gsub(/[ "]/, "", $2); print $2; exit }' terraform.tfvars)"
  fi
  if [[ -z "$region" && -f terraform.tfvars ]]; then
    region="$(awk -F= '$1 ~ /^[[:space:]]*aws_region[[:space:]]*$/ { gsub(/[ "]/, "", $2); print $2; exit }' terraform.tfvars)"
  fi

  if [[ -z "$cluster_name" || -z "$region" ]]; then
    echo "error: cannot clean up Karpenter Kubernetes resources — cluster outputs are missing." >&2
    exit 1
  fi

  kubeconfig="${TMPDIR:-/tmp}/${cluster_name}-destroy-kubeconfig"

  echo
  echo "--- configure temporary kubeconfig (${cluster_name}) ---"
  aws eks update-kubeconfig \
    --region "$region" \
    --name "$cluster_name" \
    --alias "$cluster_name" \
    --kubeconfig "$kubeconfig"

  echo
  echo "--- delete Karpenter NodePools ---"
  KUBECONFIG="$kubeconfig" kubectl delete nodepools.karpenter.sh \
    app-graviton app-x86 system \
    --ignore-not-found=true \
    --wait=false

  echo
  echo "--- remove EC2NodeClass finalizers and delete EC2NodeClasses ---"
  KUBECONFIG="$kubeconfig" kubectl patch ec2nodeclasses.karpenter.k8s.aws \
    default-arm64 default-x86 \
    --type=merge \
    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  KUBECONFIG="$kubeconfig" kubectl delete ec2nodeclasses.karpenter.k8s.aws \
    default-arm64 default-x86 \
    --ignore-not-found=true \
    --wait=false

  echo
  echo "--- uninstall Karpenter Helm release ---"
  KUBECONFIG="$kubeconfig" helm uninstall karpenter -n kube-system 2>/dev/null || \
    echo "note: Helm release 'karpenter' was already absent."

  state_rm_existing \
    "module.karpenter.helm_release.karpenter" \
    "module.karpenter.kubectl_manifest.nodepool_app_graviton" \
    "module.karpenter.kubectl_manifest.nodepool_app_x86" \
    "module.karpenter.kubectl_manifest.nodepool_system" \
    "module.karpenter.kubectl_manifest.ec2nodeclass_arm64" \
    "module.karpenter.kubectl_manifest.ec2nodeclass_x86"
}

delete_kubectl_context() {
  local context_name="$1"

  if [[ -z "$context_name" ]]; then
    echo "note: unable to delete kubectl context — cluster output was missing before destroy."
    return 0
  fi

  echo
  echo "--- delete kubectl context (${context_name}) ---"
  kubectl config delete-context "$context_name" 2>/dev/null || \
    echo "note: kubectl context '${context_name}' was already absent."
}

# Build the reversed stage list.
REVERSED=()
for ((i=${#STAGES[@]}-1; i>=0; i--)); do
  REVERSED+=("${STAGES[$i]}")
done

for entry in "${REVERSED[@]}"; do
  IFS='|' read -r name dir desc init_args pre_destroy_cleanup <<< "$entry"

  if [[ -n "$ONLY_STAGE" && "$ONLY_STAGE" != "$name" ]]; then
    continue
  fi

  echo
  echo "================================================================"
  echo "STAGE   : $name (destroy)"
  echo "DIR     : $dir"
  echo "PURPOSE : $desc"
  echo "MODE    : $([[ "$APPLY" == true ]] && echo 'destroy plan + apply' || echo 'destroy plan only')"
  echo "================================================================"

  if [[ ! -d "$dir" ]]; then
    echo "note: directory not found, nothing to destroy: $dir"
    continue
  fi

  if [[ -f "${dir}/backend.hcl.example" && ! -f "${dir}/backend.hcl" ]]; then
    echo "note: ${dir}/backend.hcl missing — stage was never applied (or already fully destroyed), skipping."
    continue
  fi

  if [[ "$name" == "bootstrap" && "$APPLY" == true ]]; then
    guard_bootstrap_destroy
  fi

  pushd "$dir" > /dev/null

  echo
  echo "--- terraform init ---"
  # shellcheck disable=SC2086
  terraform init -input=false $init_args

  # Destroy Kubernetes/Helm resources outside Terraform's kubectl provider while
  # the EKS API endpoint still exists. During destroy, that provider can
  # evaluate soon-to-be-destroyed module.eks outputs as empty and fall back to
  # localhost, so using kubectl/helm directly is more reliable here.
  if [[ "$pre_destroy_cleanup" == "karpenter" ]]; then
    if [[ "$APPLY" == true ]]; then
      cleanup_karpenter_kubernetes
    else
      echo
      echo "note: full destroy below may fail if Kubernetes resources still exist."
      echo "      Rerun with --apply so this script deletes Karpenter Kubernetes"
      echo "      resources first while the EKS endpoint is still available."
    fi
  fi

  echo
  echo "--- terraform plan -destroy ---"
  terraform plan -destroy -input=false -out="${name}.destroy.tfplan"

  kubectl_context=""
  if [[ "$name" == "dev" && "$APPLY" == true ]]; then
    kubectl_context="$(terraform state show -no-color 'module.eks.module.eks.aws_eks_cluster.this[0]' 2>/dev/null | awk '$1 == "id" && $2 == "=" { gsub("\"", "", $3); print $3; exit }')"
  fi

  if [[ "$APPLY" == true ]]; then
    echo
    echo "--- terraform apply (${name}.destroy.tfplan) ---"
    terraform apply "${name}.destroy.tfplan"

    if [[ "$name" == "dev" ]]; then
      delete_kubectl_context "$kubectl_context"
    fi
  fi

  popd > /dev/null

  echo
  if [[ "$APPLY" == true ]]; then
    echo "stage '$name' destroyed OK"
  else
    echo "stage '$name' destroy-planned OK -> ${dir}/${name}.destroy.tfplan"
  fi
done

echo
if [[ "$APPLY" == true ]]; then
  echo "All requested stages destroyed."
else
  echo "All requested stages destroy-planned (dev, then bootstrap)."
  echo "Review each *.destroy.tfplan, then rerun with --apply to destroy in the same order."
fi
