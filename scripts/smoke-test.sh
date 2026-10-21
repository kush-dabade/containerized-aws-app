#!/usr/bin/env bash
# START step 4: find the running task's public IP and verify over HTTP that
# GET /health and GET / succeed. Writes the URL to app-url.txt.

# shellcheck disable=SC2016  # JMESPath literals use backticks
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

print_recent_logs() {
  local since=$((($(date +%s) - 900) * 1000))
  warn "Container logs from the last 15 minutes:"
  aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$since" \
    --limit 50 --query 'events[].message' --output text >&2 || true
}

# Retry a URL until it returns 2xx; print the body on success.
fetch() {
  local url="$1" attempt
  for attempt in $(seq 1 "${SMOKE_ATTEMPTS:-12}"); do
    if curl -fsS --max-time 5 "$url"; then
      return 0
    fi
    log "GET $url not ready (attempt $attempt); retrying in 5s" >&2
    sleep 5
  done
  return 1
}

require_cmd curl
init_aws

cluster="$(cluster_status)"
[[ "$cluster" == "ACTIVE" ]] || die "Cluster $ECS_CLUSTER is not ACTIVE (status: ${cluster:-MISSING})"
service="$(service_status)"
[[ "$service" == "ACTIVE" ]] || die "Service $ECS_SERVICE is not ACTIVE (status: ${service:-MISSING})"
task_def_arn="$(aws_text ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].deployments[?status==`PRIMARY`] | [0].taskDefinition')"

task_arns="$(aws_text ecs list-tasks --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
  --desired-status RUNNING --query 'taskArns')"
[[ -n "$task_arns" ]] || die "No running tasks in $ECS_SERVICE"

# shellcheck disable=SC2086
eni_id="$(aws_text ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks $task_arns \
  --query "tasks[?taskDefinitionArn=='$task_def_arn' && lastStatus=='RUNNING'] | [0].attachments[0].details[?name=='networkInterfaceId'] | [0].value")"
[[ -n "$eni_id" ]] || die "No RUNNING task of $task_def_arn has a network interface yet"

public_ip="$(aws_text ec2 describe-network-interfaces --network-interface-ids "$eni_id" \
  --query 'NetworkInterfaces[0].Association.PublicIp')"
[[ -n "$public_ip" ]] || die "Task interface $eni_id has no public IP"

url="http://$public_ip:$CONTAINER_PORT"
log "Smoke testing $url"

if ! health="$(fetch "$url/health")"; then
  print_recent_logs
  die "GET $url/health failed (check that ALLOWED_CIDR covers this machine's public IP)"
fi
grep -q '"status":"ok"' <<<"$health" || die "GET /health returned an unexpected body: $health"
log "GET /health OK"

if ! body="$(fetch "$url/")"; then
  print_recent_logs
  die "GET $url/ failed"
fi
grep -qF "$APP_EXPECTED_TEXT" <<<"$body" || die "GET / did not contain '$APP_EXPECTED_TEXT'"
log "GET / OK"

printf '%s\n' "$url" >"$PROJECT_ROOT/app-url.txt"
log "Smoke test passed. Application URL: $url"
