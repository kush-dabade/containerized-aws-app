#!/usr/bin/env bash
# START step 3: register a task definition revision for the commit's image
# and create or update the ECS service, then wait for it to become stable.
# The deployment circuit breaker rolls back automatically if tasks fail.

# shellcheck disable=SC2016  # JMESPath literals use backticks
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

print_failure_diagnostics() {
  warn "Recent service events:"
  aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
    --query 'services[0].events[:8].[createdAt,message]' --output text >&2 || true
  local stopped
  stopped="$(aws_text ecs list-tasks --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
    --desired-status STOPPED --query 'taskArns[:5]')" || return 0
  if [[ -n "$stopped" ]]; then
    warn "Recently stopped tasks:"
    # shellcheck disable=SC2086
    aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks $stopped \
      --query 'tasks[].[stoppedReason,containers[0].reason]' --output text >&2 || true
  fi
}

require_cmd envsubst
init_aws

tag="$(resolve_image_tag)"
export IMAGE_URI="$ECR_URI:$tag"
ecr_image_exists "$tag" || die "Image $IMAGE_URI is not in ECR; run build-push.sh first"
iam_role_exists || die "IAM role $EXEC_ROLE_NAME is missing; run provision.sh first"
log_group_exists || die "Log group $LOG_GROUP is missing; run provision.sh first"
cluster="$(wait_for_cluster_settled)"
[[ "$cluster" == "ACTIVE" ]] || die "Cluster $ECS_CLUSTER is not ACTIVE; run provision.sh first"

vpc_id="$(default_vpc_id)"
[[ -n "$vpc_id" ]] || die "No default VPC in $AWS_REGION"
sg_id="$(security_group_id "$vpc_id")"
[[ -n "$sg_id" ]] || die "Security group $SG_NAME is missing; run provision.sh first"
subnets="$(default_subnet_ids "$vpc_id")"
[[ -n "$subnets" ]] || die "No default subnets in $vpc_id"

task_def_json="$(render_template "$PROJECT_ROOT/task-definition.template.json")"
task_def_arn="$(aws_text ecs register-task-definition --cli-input-json "$task_def_json" \
  --query taskDefinition.taskDefinitionArn)"
log "Registered $task_def_arn"

network="awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=ENABLED}"
deployment="deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=200,minimumHealthyPercent=100"

status="$(service_status)"
if [[ "$status" == "DRAINING" ]]; then
  log "Service $ECS_SERVICE is still draining from a previous STOP; waiting"
  aws ecs wait services-inactive --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
  status="INACTIVE"
fi

if [[ "$status" == "ACTIVE" ]]; then
  log "Updating service $ECS_SERVICE"
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
    --task-definition "$task_def_arn" --desired-count 1 \
    --network-configuration "$network" \
    --deployment-configuration "$deployment" >/dev/null
else
  log "Creating service $ECS_SERVICE (Fargate, 1 task, public IP)"
  aws ecs create-service --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
    --task-definition "$task_def_arn" --desired-count 1 \
    --launch-type FARGATE --platform-version LATEST \
    --network-configuration "$network" \
    --deployment-configuration "$deployment" \
    --tags "key=Project,value=$PROJECT_TAG" >/dev/null
fi

log "Waiting for the service to become stable (up to 10 minutes)"
if ! aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"; then
  print_failure_diagnostics
  die "Service did not become stable"
fi

primary="$(aws_text ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].deployments[?status==`PRIMARY`] | [0].[taskDefinition,rolloutState]')"
read -r primary_td rollout <<<"$primary"
if [[ "$primary_td" != "$task_def_arn" || "$rollout" != "COMPLETED" ]]; then
  print_failure_diagnostics
  die "Deployment of $task_def_arn did not complete (primary=$primary_td, rollout=$rollout); the circuit breaker may have rolled back"
fi
log "Deployment complete: $task_def_arn running image $IMAGE_URI"
