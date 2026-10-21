#!/usr/bin/env bash
# STOP: delete the experiment's runtime resources: the ECS service and
# cluster, every revision of the task definition family (including leftovers
# from earlier manual runs), the CloudWatch log group and every security
# group tagged Project=$PROJECT_TAG. The ECR repository, its images and the
# execution role are kept; full-cleanup.sh removes those, separately approved.
# Anything already gone is skipped. A cluster in a transitional state is
# waited on; one that never settles (or is FAILED) makes this script fail.
#
# Requires CONFIRM_STOP=yes.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

delete_service_and_cluster() {
  local status running stopping
  status="$(wait_for_cluster_settled)"
  if [[ "$status" != "ACTIVE" ]]; then
    log "ECS cluster $ECS_CLUSTER already gone (status: ${status:-MISSING})"
    return
  fi

  status="$(service_status)"
  if [[ "$status" == "ACTIVE" ]]; then
    log "Scaling $ECS_SERVICE to 0 and deleting it"
    aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --desired-count 0 >/dev/null
    aws ecs delete-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --force >/dev/null
    status="DRAINING"
  fi
  if [[ "$status" == "DRAINING" ]]; then
    log "Waiting for $ECS_SERVICE to become INACTIVE"
    aws ecs wait services-inactive --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
  fi

  # delete-cluster refuses while any task is still running or stopping.
  running="$(aws_text ecs list-tasks --cluster "$ECS_CLUSTER" --desired-status RUNNING --query taskArns)"
  stopping="$(aws_text ecs list-tasks --cluster "$ECS_CLUSTER" --desired-status STOPPED --query taskArns)"
  if [[ -n "$running$stopping" ]]; then
    log "Waiting for tasks to stop"
    # shellcheck disable=SC2086
    aws ecs wait tasks-stopped --cluster "$ECS_CLUSTER" --tasks $running $stopping
  fi

  log "Deleting ECS cluster $ECS_CLUSTER"
  aws ecs delete-cluster --cluster "$ECS_CLUSTER" >/dev/null
  status="$(wait_for_cluster_settled)"
  [[ "$status" != "ACTIVE" ]] || die "Cluster $ECS_CLUSTER is still ACTIVE after delete-cluster"
  log "ECS cluster $ECS_CLUSTER deleted (status: ${status:-MISSING})"
}

delete_task_definitions() {
  local active inactive arn failures
  local -a pending batch

  active="$(task_definition_arns ACTIVE)"
  for arn in $active; do
    log "Deregistering $arn"
    aws ecs deregister-task-definition --task-definition "$arn" >/dev/null
  done

  inactive="$(task_definition_arns INACTIVE)"
  read -r -a pending <<<"$(tr '\n' ' ' <<<"$inactive")"
  if ((${#pending[@]} == 0)); then
    log "No task definition revisions of $TASK_FAMILY left to delete"
    return
  fi
  # DeleteTaskDefinitions accepts at most 10 ARNs per call.
  while ((${#pending[@]} > 0)); do
    batch=("${pending[@]:0:10}")
    pending=("${pending[@]:10}")
    log "Deleting task definition revisions: ${batch[*]##*/}"
    failures="$(aws_text ecs delete-task-definitions --task-definitions "${batch[@]}" \
      --query 'failures[].[arn,reason]')"
    [[ -z "$failures" ]] || die "Could not delete task definitions: $failures"
  done
}

delete_log_group() {
  if log_group_exists; then
    log "Deleting log group $LOG_GROUP"
    aws logs delete-log-group --log-group-name "$LOG_GROUP"
  else
    log "Log group $LOG_GROUP already gone"
  fi
}

# Fargate releases a task's network interface a little after the task stops;
# until then the group is "in use" (DependencyViolation), so retry.
delete_security_group() {
  local sg_id="$1" attempt err
  for attempt in $(seq 1 30); do
    if err="$(aws ec2 delete-security-group --group-id "$sg_id" 2>&1 >/dev/null)"; then
      log "Deleted security group $sg_id"
      return
    fi
    [[ "$err" == *DependencyViolation* ]] || die "Could not delete security group $sg_id: $err"
    log "Security group $sg_id still attached to a network interface (attempt $attempt/30); retrying in 10s"
    sleep 10
  done
  die "Security group $sg_id is still in use after 5 minutes"
}

delete_security_groups() {
  local sg_ids sg_id
  sg_ids="$(project_security_group_ids)"
  if [[ -z "$sg_ids" ]]; then
    log "No security groups tagged Project=$PROJECT_TAG"
    return
  fi
  for sg_id in $sg_ids; do
    delete_security_group "$sg_id"
  done
}

[[ "${CONFIRM_STOP:-}" == "yes" ]] || die "Refusing to run: set CONFIRM_STOP=yes to delete the runtime resources"
init_aws
delete_service_and_cluster
delete_task_definitions
delete_log_group
delete_security_groups
log "Runtime resources deleted; ECR repository $ECR_REPO and role $EXEC_ROLE_NAME were kept"
