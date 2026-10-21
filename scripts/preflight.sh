#!/usr/bin/env bash
# Check tools, AWS identity and (with --docker) the Docker daemon.
# Read-only: makes no changes locally or in AWS.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_cmd aws curl git envsubst
init_aws

if [[ "${1:-}" == "--docker" ]]; then
  require_cmd docker
  docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 \
    || die "Docker daemon is not reachable; start Docker Desktop and check its WSL integration"
  log "Docker engine $(docker info --format '{{.ServerVersion}}') is reachable"
fi

log "Preflight passed for $ECS_CLUSTER/$ECS_SERVICE in $AWS_REGION"
