#!/usr/bin/env bash
# START step 1: create or reconcile the infrastructure the service runs on.
# Safe to re-run; every resource is looked up before it is created.
#
# Creates (if missing): ECR repository + lifecycle policy, task execution
# role, CloudWatch log group, security group, ECS cluster.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_ecr_repository() {
  if ecr_repo_exists; then
    log "ECR repository $ECR_REPO exists"
  else
    log "Creating ECR repository $ECR_REPO (immutable tags, scan on push)"
    aws ecr create-repository --repository-name "$ECR_REPO" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
  fi

  local policy
  policy="$(cat <<EOF
{"rules":[
  {"rulePriority":1,"description":"Expire untagged images after 1 day",
   "selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":1},
   "action":{"type":"expire"}},
  {"rulePriority":2,"description":"Keep only the newest $ECR_KEEP_IMAGES images",
   "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":$ECR_KEEP_IMAGES},
   "action":{"type":"expire"}}
]}
EOF
)"
  aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text "$policy" >/dev/null
  log "ECR lifecycle policy applied (keep $ECR_KEEP_IMAGES images)"
}

ensure_execution_role() {
  if iam_role_exists; then
    log "IAM role $EXEC_ROLE_NAME exists"
  else
    log "Creating IAM role $EXEC_ROLE_NAME"
    local trust
    trust="$(render_template "$PROJECT_ROOT/iam/ecs-task-trust-policy.json")"
    aws iam create-role --role-name "$EXEC_ROLE_NAME" \
      --assume-role-policy-document "$trust" \
      --description "Experiment 5: lets ECS pull from ECR and write CloudWatch logs" \
      --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
    aws iam wait role-exists --role-name "$EXEC_ROLE_NAME"
  fi

  local attached
  attached="$(aws_text iam list-attached-role-policies --role-name "$EXEC_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='$EXEC_ROLE_POLICY_ARN'].PolicyArn")"
  if [[ -z "$attached" ]]; then
    log "Attaching AmazonECSTaskExecutionRolePolicy"
    aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn "$EXEC_ROLE_POLICY_ARN"
    # New IAM permissions take a few seconds to propagate to ECS.
    sleep 15
  fi
}

ensure_log_group() {
  if log_group_exists; then
    log "Log group $LOG_GROUP exists"
  else
    log "Creating log group $LOG_GROUP"
    aws logs create-log-group --log-group-name "$LOG_GROUP" --tags "Project=$PROJECT_TAG"
  fi
  aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days "$LOG_RETENTION_DAYS"
}

ensure_security_group() {
  local vpc_id sg_id unowned allowed_cidr current cidr
  vpc_id="$(default_vpc_id)"
  [[ -n "$vpc_id" ]] || die "No default VPC in $AWS_REGION"
  sg_id="$(security_group_id "$vpc_id")"

  if [[ -z "$sg_id" ]]; then
    unowned="$(unowned_security_group_ids "$vpc_id")"
    [[ -z "$unowned" ]] \
      || die "Security group $SG_NAME already exists in $vpc_id without tag Project=$PROJECT_TAG ($unowned); refusing to adopt or replace it"
    log "Creating security group $SG_NAME in $vpc_id"
    sg_id="$(aws_text ec2 create-security-group --group-name "$SG_NAME" \
      --description "Experiment 5: inbound TCP $CONTAINER_PORT to the ECS task" \
      --vpc-id "$vpc_id" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
      --query GroupId)"
  else
    log "Security group $SG_NAME exists ($sg_id)"
  fi

  allowed_cidr="$(resolve_allowed_cidr)"
  current="$(aws_text ec2 describe-security-groups --group-ids "$sg_id" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`$CONTAINER_PORT\`].IpRanges[].CidrIp")"
  current="$(tr '\t\n' '  ' <<<"$current")"

  for cidr in $current; do
    if [[ "$cidr" != "$allowed_cidr" ]]; then
      log "Revoking stale ingress $cidr -> $CONTAINER_PORT"
      aws ec2 revoke-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port "$CONTAINER_PORT" --cidr "$cidr" >/dev/null
    fi
  done
  if [[ " $current " != *" $allowed_cidr "* ]]; then
    log "Allowing ingress $allowed_cidr -> $CONTAINER_PORT"
    aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
      --protocol tcp --port "$CONTAINER_PORT" --cidr "$allowed_cidr" >/dev/null
  else
    log "Ingress $allowed_cidr -> $CONTAINER_PORT already allowed"
  fi
}

ensure_cluster() {
  local status
  status="$(wait_for_cluster_settled)"
  if [[ "$status" == "ACTIVE" ]]; then
    log "ECS cluster $ECS_CLUSTER exists"
    return
  fi
  log "Creating ECS cluster $ECS_CLUSTER (Container Insights off to avoid extra cost)"
  aws ecs create-cluster --cluster-name "$ECS_CLUSTER" \
    --settings name=containerInsights,value=disabled \
    --tags "key=Project,value=$PROJECT_TAG" >/dev/null
  status="$(wait_for_cluster_settled)"
  [[ "$status" == "ACTIVE" ]] || die "Cluster $ECS_CLUSTER did not become ACTIVE (status: ${status:-MISSING})"
}

require_cmd curl envsubst
init_aws
ensure_ecr_repository
ensure_execution_role
ensure_log_group
ensure_security_group
ensure_cluster
log "Infrastructure is ready"
