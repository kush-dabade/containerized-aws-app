#!/usr/bin/env bash
# Shared configuration and helpers for the Experiment 5 scripts.
# Source this file; do not run it directly. Every setting below can be
# overridden through the environment.

set -euo pipefail
shopt -s inherit_errexit

# --- Configuration ----------------------------------------------------------

export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

export PROJECT_TAG="${PROJECT_TAG:-containerized-aws-app}"
export ECR_REPO="${ECR_REPO:-containerized-aws-app}"
export ECS_CLUSTER="${ECS_CLUSTER:-containerized-aws-cluster}"
export ECS_SERVICE="${ECS_SERVICE:-containerized-aws-service}"
export TASK_FAMILY="${TASK_FAMILY:-containerized-aws-task}"
export CONTAINER_NAME="${CONTAINER_NAME:-containerized-app}"
export CONTAINER_PORT="${CONTAINER_PORT:-3000}"
export TASK_CPU="${TASK_CPU:-256}"
export TASK_MEMORY="${TASK_MEMORY:-512}"
export EXEC_ROLE_NAME="${EXEC_ROLE_NAME:-containerized-aws-task-exec-role}"
export SG_NAME="${SG_NAME:-containerized-app-sg}"
export LOG_GROUP="${LOG_GROUP:-/ecs/containerized-aws-task}"
export LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-1}"
export ECR_KEEP_IMAGES="${ECR_KEEP_IMAGES:-10}"

# shellcheck disable=SC2034  # used by the scripts that source this file
readonly EXEC_ROLE_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
# shellcheck disable=SC2034
readonly APP_EXPECTED_TEXT="Application is running successfully!"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
# shellcheck disable=SC2034
readonly SCRIPT_DIR="$PROJECT_ROOT/scripts"

# Variables that templates (task definition, IAM documents) may reference.
# Anything else that looks like ${VAR} is left untouched by envsubst.
# shellcheck disable=SC2016  # literal placeholders for envsubst
readonly TEMPLATE_VARS='${AWS_ACCOUNT_ID} ${AWS_REGION} ${PROJECT_TAG} ${ECR_REPO} ${ECS_CLUSTER} ${ECS_SERVICE} ${TASK_FAMILY} ${CONTAINER_NAME} ${CONTAINER_PORT} ${TASK_CPU} ${TASK_MEMORY} ${EXEC_ROLE_NAME} ${EXEC_ROLE_ARN} ${IMAGE_URI} ${LOG_GROUP} ${DEFAULT_VPC_ID}'

# --- Logging ----------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

# --- AWS session ------------------------------------------------------------

# Resolve the caller identity and derived names. Refuses the root user.
init_aws() {
  require_cmd aws
  local ident
  ident="$(aws sts get-caller-identity --query '[Account,Arn]' --output text)" \
    || die "AWS credentials are missing, invalid or expired"
  read -r AWS_ACCOUNT_ID CALLER_ARN <<<"$ident"
  [[ "$CALLER_ARN" == *":root" ]] \
    && die "Refusing to run as the AWS account root user; use the project deployer IAM user"
  export AWS_ACCOUNT_ID CALLER_ARN
  export ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
  export ECR_URI="$ECR_REGISTRY/$ECR_REPO"
  export EXEC_ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/$EXEC_ROLE_NAME"
  log "AWS caller: $CALLER_ARN (region $AWS_REGION)"
}

# Print the text output of an AWS CLI call, mapping "None" to empty.
# The CLI runs exactly once (it may be a mutating call). Any failure is fatal,
# so an error is never mistaken for an empty result. Callers must capture the
# output with a plain assignment (x="$(aws_text ...)"), never inside [[ ]],
# a here-string or a for-list, where bash would discard the failure.
aws_text() {
  local out
  out="$(aws "$@" --output text)" || die "AWS CLI call failed: aws $1 $2"
  [[ "$out" == "None" ]] && out=""
  printf '%s' "$out"
}

# --- Templates --------------------------------------------------------------

# shellcheck disable=SC2016
render_template() {
  local rendered
  rendered="$(envsubst "$TEMPLATE_VARS" <"$1")"
  if grep -q '\${' <<<"$rendered"; then
    die "Unresolved placeholder in $1: $(grep -o '\${[A-Z_]*}' <<<"$rendered" | sort -u | tr '\n' ' ')"
  fi
  printf '%s\n' "$rendered"
}

# --- Image tag --------------------------------------------------------------

# Image tags are the first 12 characters of the Git commit SHA. Jenkins sets
# GIT_COMMIT; local runs fall back to the checked-out HEAD.
resolve_image_tag() {
  if [[ -n "${IMAGE_TAG:-}" ]]; then
    printf '%s\n' "$IMAGE_TAG"
    return
  fi
  local sha="${GIT_COMMIT:-}"
  if [[ -z "$sha" ]]; then
    sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  fi
  printf '%s\n' "${sha:0:12}"
}

# --- Resource lookups (read-only) -------------------------------------------

ecr_repo_exists() {
  local err
  if err="$(aws ecr describe-repositories --repository-names "$ECR_REPO" 2>&1 >/dev/null)"; then
    return 0
  fi
  [[ "$err" == *RepositoryNotFoundException* ]] && return 1
  die "Could not look up ECR repository $ECR_REPO: $err"
}

ecr_image_exists() {
  local err
  if err="$(aws ecr describe-images --repository-name "$ECR_REPO" --image-ids "imageTag=$1" 2>&1 >/dev/null)"; then
    return 0
  fi
  [[ "$err" == *ImageNotFoundException* || "$err" == *RepositoryNotFoundException* ]] && return 1
  die "Could not look up image $ECR_REPO:$1: $err"
}

iam_role_exists() {
  local err
  if err="$(aws iam get-role --role-name "$EXEC_ROLE_NAME" 2>&1 >/dev/null)"; then
    return 0
  fi
  [[ "$err" == *NoSuchEntity* ]] && return 1
  die "Could not look up IAM role $EXEC_ROLE_NAME: $err"
}

log_group_exists() {
  local found
  found="$(aws_text logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName")" || exit 1
  [[ -n "$found" ]]
}

default_vpc_id() {
  aws_text ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId'
}

# Comma-separated default subnets of the default VPC (all are public).
default_subnet_ids() {
  aws_text ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$1" Name=default-for-az,Values=true \
    --query 'Subnets[].SubnetId' | tr '\t' ','
}

# The project security group in VPC $1, matched by VPC, name AND Project tag.
# Prints nothing if there is none; fails if more than one group matches.
security_group_id() {
  local found
  local -a ids
  found="$(aws_text ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$1" "Name=group-name,Values=$SG_NAME" "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[].GroupId')" || exit 1
  read -r -a ids <<<"$found"
  ((${#ids[@]} <= 1)) \
    || die "Ambiguous: ${#ids[@]} security groups named $SG_NAME tagged Project=$PROJECT_TAG in $1 (${ids[*]}); resolve this manually"
  printf '%s' "${ids[0]:-}"
}

# Groups named $SG_NAME in VPC $1 that are NOT tagged for this project.
unowned_security_group_ids() {
  aws_text ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$1" "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[?!(Tags[?Key=='Project' && Value=='$PROJECT_TAG'])].GroupId"
}

# Every security group in the region tagged Project=$PROJECT_TAG, any VPC.
project_security_group_ids() {
  aws_text ec2 describe-security-groups \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'SecurityGroups[].GroupId'
}

# ACTIVE, PROVISIONING, DEPROVISIONING, FAILED or INACTIVE; empty only when
# ECS reports the cluster MISSING. Any other lookup failure is fatal.
cluster_status() {
  local out status reason
  out="$(aws_text ecs describe-clusters --clusters "$ECS_CLUSTER" \
    --query '[clusters[0].status, failures[0].reason]')" || exit 1
  read -r status reason <<<"$out"
  [[ "$status" == "None" ]] && status=""
  [[ -n "$status" || "$reason" == "MISSING" ]] \
    || die "Could not determine the status of cluster $ECS_CLUSTER (failure reason: ${reason:-none})"
  printf '%s\n' "$status"
}

# ACTIVE, DRAINING or INACTIVE; empty only when ECS reports the service
# MISSING. Requires an existing cluster. Any other lookup failure is fatal.
service_status() {
  local out status reason
  out="$(aws_text ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
    --query '[services[0].status, failures[0].reason]')" || exit 1
  read -r status reason <<<"$out"
  [[ "$status" == "None" ]] && status=""
  [[ -n "$status" || "$reason" == "MISSING" ]] \
    || die "Could not determine the status of service $ECS_SERVICE (failure reason: ${reason:-none})"
  printf '%s\n' "$status"
}

# Wait out PROVISIONING / DEPROVISIONING. Prints ACTIVE, INACTIVE or empty
# (missing). Fails on FAILED or unknown states, or if the cluster does not
# settle in time, so no caller proceeds on a transitional cluster.
wait_for_cluster_settled() {
  local status attempt attempts="${CLUSTER_WAIT_ATTEMPTS:-30}"
  for attempt in $(seq 1 "$attempts"); do
    status="$(cluster_status)"
    case "$status" in
      "" | ACTIVE | INACTIVE)
        printf '%s\n' "$status"
        return 0
        ;;
      PROVISIONING | DEPROVISIONING)
        log "Cluster $ECS_CLUSTER is $status (check $attempt/$attempts); waiting 10s" >&2
        sleep 10
        ;;
      *)
        die "Cluster $ECS_CLUSTER is in state $status; investigate it in the ECS console before retrying"
        ;;
    esac
  done
  die "Cluster $ECS_CLUSTER is still $status after $attempts checks; not proceeding"
}

# Task definition ARNs of exactly $TASK_FAMILY (the API matches by prefix).
task_definition_arns() {
  local arns arn
  arns="$(aws_text ecs list-task-definitions --family-prefix "$TASK_FAMILY" \
    --status "$1" --query 'taskDefinitionArns[]')" || exit 1
  for arn in $arns; do
    [[ "$arn" =~ :task-definition/${TASK_FAMILY}:[0-9]+$ ]] && printf '%s\n' "$arn"
  done
  return 0
}

# --- Networking -------------------------------------------------------------

# ALLOWED_CIDR if set, otherwise this machine's public IPv4 as a /32.
resolve_allowed_cidr() {
  local cidr="${ALLOWED_CIDR:-}"
  if [[ -z "$cidr" ]]; then
    local ip
    ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')" \
      || die "Could not detect the public IP; set ALLOWED_CIDR"
    cidr="$ip/32"
  fi
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] \
    || die "ALLOWED_CIDR '$cidr' is not an IPv4 CIDR"
  [[ "$cidr" == "0.0.0.0/0" ]] \
    && warn "ALLOWED_CIDR is 0.0.0.0/0: port $CONTAINER_PORT will be open to the whole internet"
  printf '%s\n' "$cidr"
}
