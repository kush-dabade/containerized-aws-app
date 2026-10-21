#!/usr/bin/env bash
# FULL_CLEANUP, second step: delete the ECR repository with ALL of its images
# and the ECS task execution role. Irreversible.
#
# Run STOP (deprovision.sh) first; this refuses while the ECS cluster exists.
# It needs the separate full-cleanup identity (iam/full-cleanup-policy.json):
# the normal deployer identity is deliberately unable to delete the
# repository or the role.
#
# Requires CONFIRM_FULL_CLEANUP=<ECR repository name>.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

delete_ecr_repository() {
  local count
  if ! ecr_repo_exists; then
    log "ECR repository $ECR_REPO already gone"
    return
  fi
  count="$(aws_text ecr describe-images --repository-name "$ECR_REPO" --query 'length(imageDetails)')"
  log "Deleting ECR repository $ECR_REPO and its ${count:-0} image(s)"
  aws ecr delete-repository --repository-name "$ECR_REPO" --force >/dev/null
}

delete_execution_role() {
  local attached arn
  if ! iam_role_exists; then
    log "IAM role $EXEC_ROLE_NAME already gone"
    return
  fi
  attached="$(aws_text iam list-attached-role-policies --role-name "$EXEC_ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyArn')"
  for arn in $attached; do
    [[ "$arn" == "$EXEC_ROLE_POLICY_ARN" ]] \
      || die "Role $EXEC_ROLE_NAME has an unexpected policy attached ($arn); refusing to delete it"
    log "Detaching $arn"
    aws iam detach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn "$arn"
  done
  log "Deleting IAM role $EXEC_ROLE_NAME"
  aws iam delete-role --role-name "$EXEC_ROLE_NAME"
}

[[ "${CONFIRM_FULL_CLEANUP:-}" == "$ECR_REPO" ]] \
  || die "Refusing to run: set CONFIRM_FULL_CLEANUP=$ECR_REPO to delete the repository, all images and the role"
init_aws

cluster="$(cluster_status)"
[[ -z "$cluster" || "$cluster" == "INACTIVE" ]] \
  || die "ECS cluster $ECS_CLUSTER still exists (status $cluster); run STOP and verify it first"

delete_ecr_repository
delete_execution_role
log "ECR repository and execution role deleted"
