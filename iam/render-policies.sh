#!/usr/bin/env bash
# Render the IAM policy templates for this account into iam/rendered/
# (or RENDER_OUT_DIR).
# Read-only: it only calls sts:GetCallerIdentity and ec2:DescribeVpcs, and
# skips both when AWS_ACCOUNT_ID and DEFAULT_VPC_ID are already set.
#
#   iam/render-policies.sh
#   AWS_ACCOUNT_ID=123456789012 DEFAULT_VPC_ID=vpc-0abc iam/render-policies.sh

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

require_cmd envsubst

if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
  AWS_ACCOUNT_ID="$(aws_text sts get-caller-identity --query Account)"
fi
if [[ -z "${DEFAULT_VPC_ID:-}" ]]; then
  DEFAULT_VPC_ID="$(default_vpc_id)"
fi
[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS_ACCOUNT_ID '$AWS_ACCOUNT_ID' is not a 12-digit account ID"
[[ "$DEFAULT_VPC_ID" == vpc-* ]] || die "No default VPC found in $AWS_REGION; set DEFAULT_VPC_ID"
export AWS_ACCOUNT_ID DEFAULT_VPC_ID

out_dir="${RENDER_OUT_DIR:-$PROJECT_ROOT/iam/rendered}"
mkdir -p "$out_dir"

for name in jenkins-deployer-policy full-cleanup-policy ecs-task-trust-policy; do
  render_template "$PROJECT_ROOT/iam/$name.json" >"$out_dir/$name.json"
  # Managed policies are limited to 6,144 characters excluding whitespace.
  size="$(tr -d '[:space:]' <"$out_dir/$name.json" | wc -c)"
  ((size <= 6144)) || die "$name.json is $size characters; the managed policy limit is 6144"
  log "Wrote $out_dir/$name.json ($size characters without whitespace)"
done
