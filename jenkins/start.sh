#!/usr/bin/env bash
# Build and start the Experiment 5 Jenkins container (http://localhost:8080).
# Stop it with:   docker compose -f jenkins/compose.yaml stop
# Remove it with: docker compose -f jenkins/compose.yaml down
#   (add -v to also delete the jenkins_home volume: jobs, credentials, history)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

docker info >/dev/null 2>&1 \
  || { echo "Docker engine is not reachable; start Docker Desktop and enable WSL integration" >&2; exit 1; }

docker compose build

# Group that owns the Docker socket as seen from inside a container.
DOCKER_GID="$(docker run --rm --entrypoint stat -v /var/run/docker.sock:/var/run/docker.sock \
  exp5-jenkins:2.580.1 -c %g /var/run/docker.sock)"
export DOCKER_GID

docker compose up -d
docker exec exp5-jenkins docker version --format 'Jenkins can reach Docker engine {{.Server.Version}}'

echo "Jenkins is starting at http://localhost:8080"
echo "Initial admin password: docker exec exp5-jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
