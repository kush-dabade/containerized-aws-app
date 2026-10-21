#!/usr/bin/env bash
# Build and start the local Experiment 5 Jenkins controller.
#
#   jenkins/start.sh                                   UI on http://localhost:8080
#   JENKINS_PORT=8081 jenkins/start.sh                 another localhost port
#   EXP5_REPO_URL=https://github.com/<you>/<repo>.git jenkins/start.sh
#                                                      job clones GitHub instead
#                                                      (only affects a newly created job)
#
# Stop (keeps all data):  docker compose -f jenkins/compose.yaml stop
# Reset (DELETES jobs, credentials and history):
#                         docker compose -f jenkins/compose.yaml down -v
#
# This script never starts a build; the job only runs when you start it.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v docker >/dev/null 2>&1 \
  || { echo "docker not found in WSL; enable Docker Desktop > Settings > Resources > WSL integration for this distro" >&2; exit 1; }
docker info >/dev/null 2>&1 \
  || { echo "Docker engine is not reachable; start Docker Desktop and check its WSL integration" >&2; exit 1; }

docker compose build

# Group that owns the Docker socket as seen from inside a container.
DOCKER_GID="$(docker run --rm --entrypoint stat -v /var/run/docker.sock:/var/run/docker.sock \
  exp5-jenkins:2.580.1 -c %g /var/run/docker.sock)"
export DOCKER_GID

docker compose up -d --wait
docker compose exec -T jenkins docker version --format 'Jenkins can reach Docker engine {{.Server.Version}}'

port="${JENKINS_PORT:-8080}"
echo "Jenkins: http://localhost:$port  (job: experiment5-containerized-app)"
if docker compose exec -T jenkins test -f /var/jenkins_home/secrets/initialAdminPassword; then
  echo "First start: unlock Jenkins with the password printed by"
  echo "  docker compose -f jenkins/compose.yaml exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
fi
