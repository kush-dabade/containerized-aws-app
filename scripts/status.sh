#!/usr/bin/env bash
# STATUS: read-only report of every experiment resource and the app URL.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

row() { printf '  %-22s %s\n' "$1" "$2"; }

init_aws
echo
echo "Experiment 5 resources in $AWS_REGION"

if ecr_repo_exists; then
  count="$(aws_text ecr describe-images --repository-name "$ECR_REPO" --query 'length(imageDetails)')"
  newest="$(aws_text ecr describe-images --repository-name "$ECR_REPO" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]')"
  row "ECR repository" "$ECR_REPO (${count:-0} images, newest tag: ${newest:-none})"
else
  row "ECR repository" "absent"
fi

if iam_role_exists; then row "Execution role" "$EXEC_ROLE_NAME"; else row "Execution role" "absent"; fi
if log_group_exists; then row "Log group" "$LOG_GROUP"; else row "Log group" "absent"; fi

vpc_id="$(default_vpc_id)"
sg_id=""
if [[ -n "$vpc_id" ]]; then
  sg_id="$(security_group_id "$vpc_id")"
fi
if [[ -n "$sg_id" ]]; then
  ingress="$(aws_text ec2 describe-security-groups --group-ids "$sg_id" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`$CONTAINER_PORT\`].IpRanges[].CidrIp" | tr '\t\n' '  ')"
  row "Security group" "$sg_id (port $CONTAINER_PORT from: ${ingress:-nobody})"
else
  row "Security group" "absent"
fi

active="$(task_definition_arns ACTIVE)"
inactive="$(task_definition_arns INACTIVE)"
row "Task definitions" "$(wc -w <<<"$active") active, $(wc -w <<<"$inactive") inactive (family $TASK_FAMILY)"

cluster="$(cluster_status)"
row "ECS cluster" "${cluster:-absent}"
if [[ "$cluster" == "ACTIVE" ]]; then
  service="$(service_status)"
  if [[ "$service" == "ACTIVE" || "$service" == "DRAINING" ]]; then
    counts="$(aws_text ecs describe-services --cluster "$ECS_CLUSTER" \
      --services "$ECS_SERVICE" --query 'services[0].[runningCount,desiredCount,taskDefinition]')"
    read -r running desired td <<<"$counts"
    row "ECS service" "$service, $running/$desired running, ${td##*/}"
    if ((running > 0)); then
      row "BILLING" "$running Fargate task(s) running with a public IPv4 address"
      task_arn="$(aws_text ecs list-tasks --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
        --desired-status RUNNING --query 'taskArns[0]')"
      eni_id="$(aws_text ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$task_arn" \
        --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'] | [0].value")"
      public_ip=""
      if [[ -n "$eni_id" ]]; then
        public_ip="$(aws_text ec2 describe-network-interfaces \
          --network-interface-ids "$eni_id" --query 'NetworkInterfaces[0].Association.PublicIp')"
      fi
      row "Application URL" "${public_ip:+http://$public_ip:$CONTAINER_PORT}"
    fi
  else
    row "ECS service" "${service:-absent}"
  fi
fi
echo
