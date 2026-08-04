#!/usr/bin/env bash
# Runs `terraform init` + `plan` (+ optionally `apply`) sequentially,
# stage by stage, across separate root modules (bootstrap -> environments/<env>).
#
# Stops on first failure — a later stage (e.g. environments/dev) depends on
# the previous one's output (bootstrap's S3 bucket/DynamoDB table feed
# environments/dev/backend.hcl), so running out of order or continuing
# past a failure would plan/apply against a stale/incomplete backend.
#
# bootstrap is special: it is ALWAYS init+plan+applied, even when the rest
# of the run is plan-only. It's cheap/idempotent (an S3 bucket + a DynamoDB
# table, force_destroy on), and every later stage needs its real outputs
# just to init a remote backend — planning dev against a backend.hcl that
# doesn't exist yet is a guaranteed error, not a meaningful "plan only".
# Right after bootstrap applies, this script reads its outputs and writes
# environments/dev/backend.hcl automatically so the dev stage never trips
# over a missing file.
#
# Applies always use saved plan files. That keeps `run.sh --apply` non-
# interactive while still showing the exact plan immediately before apply.
#
# Usage:
#   terraform/scripts/run.sh                 # bootstrap applied, rest plan only
#   terraform/scripts/run.sh dev              # single stage, plan only (bootstrap outputs must exist)
#   terraform/scripts/run.sh --apply          # all stages, plan + apply
#   terraform/scripts/run.sh --apply dev      # single stage, plan + apply
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP_DIR="${TF_ROOT}/bootstrap"

# Ordered stages: "name|dir|description|extra init args|pre-apply targets|always_apply"
#
# pre-apply targets (dev only): the kubernetes/helm/kubectl providers in
# environments/dev/providers.tf authenticate against module.eks's live
# cluster endpoint, so a full plan/apply against a not-yet-created cluster
# fails outright. VPC+EKS must exist first — see terraform/README.md
# Quick Start step 4. Leave empty for stages with no such dependency
# (bootstrap).
#
# always_apply ("true"/""): apply this stage's plan even when the script
# was invoked without --apply. Only bootstrap needs this — see header note.
#
# Add new environments (staging/prod) as additional lines, in the order
# they must run.
STAGES=(
  "bootstrap|${BOOTSTRAP_DIR}|Remote state backend: S3 bucket + DynamoDB lock table (local state on purpose — chicken-and-egg, see bootstrap/main.tf)|||true"
  "dev|${TF_ROOT}/environments/dev|Environment dev: VPC + EKS + Karpenter (remote state via backend.hcl)|-backend-config=backend.hcl|-target=module.vpc -target=module.eks|"
)

APPLY=false
ONLY_STAGE=""
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    *) ONLY_STAGE="$arg" ;;
  esac
done

# Writes environments/dev/backend.hcl from bootstrap's terraform outputs.
# No-op if backend.hcl already exists (never overwrite account-specific,
# gitignored, possibly hand-edited config). Errors out if bootstrap has no
# applied state to read outputs from yet.
generate_dev_backend_hcl() {
  local dev_dir="${TF_ROOT}/environments/dev"
  local backend_file="${dev_dir}/backend.hcl"

  [[ -f "$backend_file" ]] && return 0
  [[ -f "${dev_dir}/backend.hcl.example" ]] || return 0

  local bucket table region
  bucket="$(terraform -chdir="$BOOTSTRAP_DIR" output -raw bucket 2>/dev/null || true)"
  table="$(terraform -chdir="$BOOTSTRAP_DIR" output -raw dynamodb_table 2>/dev/null || true)"
  region="$(terraform -chdir="$BOOTSTRAP_DIR" output -raw region 2>/dev/null || true)"

  if [[ -z "$bucket" || -z "$table" || -z "$region" ]]; then
    echo "error: ${backend_file} missing and bootstrap has no outputs to generate it from." >&2
    echo "       run this script's bootstrap stage first (it applies automatically)," >&2
    echo "       or fill it in manually: cp ${dev_dir}/backend.hcl.example ${backend_file}" >&2
    exit 1
  fi

  cat > "$backend_file" <<EOF
bucket         = "${bucket}"
key            = "dev/${region}/terraform.tfstate"
region         = "${region}"
dynamodb_table = "${table}"
encrypt        = true
EOF
  echo "generated ${backend_file} from bootstrap outputs (bucket=${bucket}, table=${table}, region=${region})"
}

configure_kubectl_context() {
  local cluster_name region

  cluster_name="$(terraform output -raw cluster_name 2>/dev/null || true)"
  region="$(terraform output -raw aws_region 2>/dev/null || true)"

  if [[ -z "$cluster_name" || -z "$region" ]]; then
    echo "note: unable to configure kubectl context — cluster outputs are missing."
    return 0
  fi

  echo
  echo "--- configure kubectl context (${cluster_name}) ---"
  aws eks update-kubeconfig \
    --region "$region" \
    --name "$cluster_name" \
    --alias "$cluster_name"
}

for entry in "${STAGES[@]}"; do
  IFS='|' read -r name dir desc init_args pre_apply_targets always_apply <<< "$entry"

  if [[ -n "$ONLY_STAGE" && "$ONLY_STAGE" != "$name" ]]; then
    continue
  fi

  effective_apply=$APPLY
  if [[ "$always_apply" == "true" ]]; then
    effective_apply=true
  fi

  echo
  echo "================================================================"
  echo "STAGE   : $name"
  echo "DIR     : $dir"
  echo "PURPOSE : $desc"
  echo "MODE    : $([[ "$effective_apply" == true ]] && echo 'plan + apply' || echo 'plan only')$([[ "$always_apply" == "true" && "$APPLY" == false ]] && echo '  (forced: prerequisite for later stages)' || true)"
  echo "================================================================"

  if [[ ! -d "$dir" ]]; then
    echo "error: directory not found: $dir" >&2
    exit 1
  fi

  # dev's backend.hcl is generated from bootstrap's outputs (see
  # generate_dev_backend_hcl) right after the bootstrap stage applies below.
  # This only fires as a fallback, e.g. when running `run.sh dev` alone
  # against an already-applied bootstrap.
  if [[ "$name" == "dev" && -f "${dir}/backend.hcl.example" && ! -f "${dir}/backend.hcl" ]]; then
    generate_dev_backend_hcl
  fi
  if [[ -f "${dir}/terraform.tfvars.example" && ! -f "${dir}/terraform.tfvars" ]]; then
    echo "error: ${dir}/terraform.tfvars missing." >&2
    echo "       cp ${dir}/terraform.tfvars.example ${dir}/terraform.tfvars   # then edit" >&2
    exit 1
  fi

  pushd "$dir" > /dev/null

  echo
  echo "--- terraform version (installed) ---"
  terraform version

  required="$(grep -h -A1 'required_version' ./*.tf 2>/dev/null | grep -o '"[^"]*"' | head -1 || true)"
  if [[ -n "$required" ]]; then
    echo "--- required_version (declared) --- $required"
  fi

  echo
  echo "--- terraform init ---"
  # shellcheck disable=SC2086
  terraform init -input=false $init_args

  # First-run bootstrap for stages whose other providers need a live
  # cluster to even plan (dev's kubernetes/helm/kubectl providers).
  # Safe to re-run: no-op if vpc+eks already exist.
  if [[ -n "$pre_apply_targets" ]]; then
    if [[ "$effective_apply" == true ]]; then
      echo
      echo "--- terraform plan (pre-step, required before full plan): $pre_apply_targets ---"
      # shellcheck disable=SC2086
      terraform plan -input=false $pre_apply_targets -out="${name}.pre.tfplan"

      echo
      echo "--- terraform apply (${name}.pre.tfplan) ---"
      terraform apply "${name}.pre.tfplan"
    else
      echo
      echo "note: full plan below requires the cluster this stage depends on to"
      echo "      already exist ($pre_apply_targets). On a first run (nothing"
      echo "      applied yet) this plan will fail — rerun with --apply to let"
      echo "      this stage create it first, or apply it manually:"
      echo "      terraform -chdir=${dir} apply ${pre_apply_targets}"
    fi
  fi

  echo
  echo "--- terraform plan ---"
  terraform plan -input=false -out="${name}.tfplan"

  if [[ "$effective_apply" == true ]]; then
    echo
    echo "--- terraform apply (${name}.tfplan) ---"
    terraform apply "${name}.tfplan"

    if [[ "$name" == "dev" ]]; then
      configure_kubectl_context
    fi
  fi

  popd > /dev/null

  # Right after bootstrap applies, generate dev's backend.hcl so the next
  # stage in this same run never hits the missing-file error.
  if [[ "$name" == "bootstrap" && "$effective_apply" == true ]]; then
    generate_dev_backend_hcl
  fi

  echo
  if [[ "$effective_apply" == true ]]; then
    echo "stage '$name' applied OK"
  else
    echo "stage '$name' planned OK -> ${dir}/${name}.tfplan"
  fi
done

echo
if [[ "$APPLY" == true ]]; then
  echo "All requested stages applied."
else
  echo "bootstrap applied (forced); remaining stages initialized and planned."
  echo "Review each *.tfplan, then rerun with --apply to apply them in the same order."
fi
