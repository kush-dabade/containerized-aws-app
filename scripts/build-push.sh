#!/usr/bin/env bash
# START step 2: build the image, smoke-test it locally, then push it to ECR.
# The tag is the Git commit SHA. ECR tags are immutable, so an image that is
# already in ECR for this commit is reused, never rebuilt or overwritten.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

smoke_container=""

cleanup() {
  [[ -n "$smoke_container" ]] && docker rm -f "$smoke_container" >/dev/null 2>&1
  docker logout "$ECR_REGISTRY" >/dev/null 2>&1 || true
}

# Run the image and probe it from inside the container (no host ports needed).
local_smoke_test() {
  local body _
  smoke_container="smoke-$ECR_REPO-$$"
  docker run -d --rm --name "$smoke_container" "$1" >/dev/null

  for _ in $(seq 1 20); do
    docker exec "$smoke_container" wget -q -O /dev/null "http://127.0.0.1:$CONTAINER_PORT/health" 2>/dev/null \
      && break
    sleep 1
  done
  body="$(docker exec "$smoke_container" wget -q -O - "http://127.0.0.1:$CONTAINER_PORT/")" \
    || { docker logs "$smoke_container" || true; die "Local smoke test: GET / failed"; }
  grep -qF "$APP_EXPECTED_TEXT" <<<"$body" || die "Local smoke test: unexpected response body from GET /"
  log "Local smoke test passed (/health and / respond)"

  docker rm -f "$smoke_container" >/dev/null
  smoke_container=""
}

require_cmd docker git
init_aws
trap cleanup EXIT

tag="$(resolve_image_tag)"
image="$ECR_URI:$tag"

changes="$(git -C "$PROJECT_ROOT" status --porcelain)"
if [[ -z "${IMAGE_TAG:-}" && -n "$changes" ]]; then
  die "Working tree has uncommitted changes; commit them so the image tag matches its source"
fi
ecr_repo_exists || die "ECR repository $ECR_REPO is missing; run provision.sh first"

if ecr_image_exists "$tag"; then
  log "Image $image is already in ECR; skipping build and push"
  exit 0
fi

log "Building $image"
docker build --pull --platform linux/amd64 \
  --label "org.opencontainers.image.revision=$tag" \
  -t "$image" "$PROJECT_ROOT"

local_smoke_test "$image"

log "Pushing $image"
aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
docker push "$image"
log "Pushed $image"
