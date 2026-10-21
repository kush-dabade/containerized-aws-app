#!/usr/bin/env bash
# Exit non-zero unless every experiment-owned runtime resource is verifiably
# absent: ECS cluster, service and tasks, task definition revisions, log group
# and project-tagged security groups. With --full, the ECR repository and the
# execution role must be gone too. Any AWS lookup error fails verification.
# Read-only.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

full=false
[[ "${1:-}" == "--full" ]] && full=true

init_aws
remaining=()
ok() { log "OK    $*"; }

# --- ECS cluster, service, tasks --------------------------------------------
# ECS only lets a cluster become INACTIVE once it has no services and no
# running tasks, so an absent or INACTIVE cluster proves both are gone.
cluster="$(cluster_status)"
if [[ -z "$cluster" || "$cluster" == "INACTIVE" ]]; then
  ok "ECS cluster $ECS_CLUSTER is ${cluster:-absent}, so it has no services or tasks"
else
  remaining+=("ECS cluster $ECS_CLUSTER (status $cluster)")

  service="$(service_status)"
  if [[ -z "$service" || "$service" == "INACTIVE" ]]; then
    ok "ECS service $ECS_SERVICE is ${service:-absent}"
  else
    remaining+=("ECS service $ECS_SERVICE (status $service)")
  fi

  running="$(aws_text ecs list-tasks --cluster "$ECS_CLUSTER" --desired-status RUNNING --query taskArns)"
  stopping="$(aws_text ecs list-tasks --cluster "$ECS_CLUSTER" --desired-status STOPPED --query taskArns)"
  live=""
  if [[ -n "$running$stopping" ]]; then
    # shellcheck disable=SC2086
    live="$(aws_text ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks $running $stopping \
      --query "tasks[?lastStatus!='STOPPED'].[taskArn,lastStatus]")"
  fi
  while read -r task_arn task_status; do
    [[ -n "$task_arn" ]] && remaining+=("ECS task ${task_arn##*/} (status $task_status)")
  done <<<"$live"
  [[ -z "$live" ]] && ok "No running or stopping tasks in $ECS_CLUSTER"
fi

# --- Task definitions -------------------------------------------------------
# Deleted revisions move to DELETE_IN_PROGRESS; ACTIVE or INACTIVE remain.
active="$(task_definition_arns ACTIVE)"
inactive="$(task_definition_arns INACTIVE)"
for arn in $active; do
  remaining+=("Task definition ${arn##*/} (ACTIVE)")
done
for arn in $inactive; do
  remaining+=("Task definition ${arn##*/} (INACTIVE, not deleted)")
done
[[ -z "$active$inactive" ]] && ok "No ACTIVE or INACTIVE revisions of $TASK_FAMILY"

# --- Log group --------------------------------------------------------------
if log_group_exists; then
  remaining+=("Log group $LOG_GROUP")
else
  ok "Log group $LOG_GROUP is gone"
fi

# --- Security groups (tagged Project=..., in any VPC) -----------------------
sg_ids="$(project_security_group_ids)"
for sg_id in $sg_ids; do
  remaining+=("Security group $sg_id (tagged Project=$PROJECT_TAG)")
done
[[ -z "$sg_ids" ]] && ok "No security groups tagged Project=$PROJECT_TAG"

# --- ECR repository and execution role (FULL_CLEANUP only) ------------------
if ecr_repo_exists; then
  if $full; then
    remaining+=("ECR repository $ECR_REPO")
  else
    count="$(aws_text ecr describe-images --repository-name "$ECR_REPO" --query 'length(imageDetails)')"
    log "KEPT  ECR repository $ECR_REPO with ${count:-0} image(s) (by design; FULL_CLEANUP deletes it)"
  fi
else
  ok "ECR repository $ECR_REPO is gone"
fi

if iam_role_exists; then
  if $full; then
    remaining+=("IAM role $EXEC_ROLE_NAME")
  else
    log "KEPT  IAM role $EXEC_ROLE_NAME (no cost; FULL_CLEANUP deletes it)"
  fi
else
  ok "IAM role $EXEC_ROLE_NAME is gone"
fi

if ((${#remaining[@]} > 0)); then
  printf '[%s] REMAINING: %s\n' "$(date -u +%H:%M:%S)" "${remaining[@]}" >&2
  die "Cleanup verification failed: ${#remaining[@]} experiment resource(s) still exist"
fi
log "Cleanup verified: no experiment-owned runtime resources remain"
