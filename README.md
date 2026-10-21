# Containerized AWS Application

## Overview

This project demonstrates containerizing a simple Node.js/Express web application with Docker and deploying it to AWS. The image is stored in Amazon Elastic Container Registry (ECR) and run as a serverless container on Amazon Elastic Container Service (ECS) using the AWS Fargate launch type.

## Tech Stack

- Node.js
- Express
- Docker
- Amazon ECR
- Amazon ECS
- AWS Fargate

## Local Development

Install dependencies and start the server:

```bash
npm install
npm start
```

The application runs on:

```
http://localhost:3000
```

The port can be overridden with the `PORT` environment variable.

## Docker

Build the image:

```bash
docker build -t containerized-aws-app .
```

Run the container:

```bash
docker run -p 3000:3000 containerized-aws-app
```

Then open `http://localhost:3000` in a browser.

## AWS Architecture

```
Application
   ↓
Docker Image
   ↓
Amazon ECR        (private image registry)
   ↓
Amazon ECS        (cluster, task definition, service)
   ↓
AWS Fargate       (serverless compute for the task)
   ↓
VPC / Subnet      (awsvpc networking, public IP assigned to the task)
   ↓
Security Group    (inbound TCP 3000 from ALLOWED_CIDR, default: your public IP /32)
   ↓
Application       (reachable at http://<task-public-ip>:3000)
```

Logs go to CloudWatch Logs (`/ecs/containerized-aws-task`, 1-day retention). There is no load balancer or NAT gateway.

## Jenkins Operations

One parameterized Jenkins job (`Jenkinsfile`) drives the whole lifecycle in `ap-south-1`:

| ACTION         | What it does | Confirmation |
| -------------- | ------------ | ------------ |
| `STATUS`       | Read-only report of every experiment resource and the app URL (default) | none |
| `START`        | Provision infrastructure, build the image (tagged with the Git commit SHA), smoke-test it locally, push to ECR, deploy to ECS, smoke-test over HTTP | none |
| `STOP`         | Delete the ECS service, cluster, all task definition revisions, log group and security group, then verify nothing is left. **ECR and its images are kept.** | `CONFIRM=STOP` |
| `FULL_CLEANUP` | `STOP`, then after an interactive approval in Jenkins, delete the ECR repository, **all images** and the execution role using a **separate** credential | `CONFIRM=containerized-aws-app` + approval |

Every step is idempotent: re-running `START` reconciles existing resources, and re-running `STOP` skips what is already gone. A cluster in a transitional state (`PROVISIONING`/`DEPROVISIONING`) is waited on; a `FAILED` cluster or one that never settles makes the job fail rather than report success.

The normal deployer identity cannot delete the ECR repository or the execution role. Those permissions live only in `iam/full-cleanup-policy.json`, for a separate identity used solely by the last step of `FULL_CLEANUP`.

The same scripts run without Jenkins (credentials from the environment):

```bash
scripts/status.sh
ALLOWED_CIDR=203.0.113.7/32 scripts/provision.sh   # ALLOWED_CIDR optional
scripts/build-push.sh && scripts/deploy.sh && scripts/smoke-test.sh
CONFIRM_STOP=yes scripts/deprovision.sh && scripts/verify-cleanup.sh
# after STOP, with the full-cleanup identity's credentials:
CONFIRM_FULL_CLEANUP=containerized-aws-app scripts/full-cleanup.sh
scripts/verify-cleanup.sh --full
```

All scripts refuse to run as the AWS root user.

### One-time setup

1. **IAM identities** (as an administrator, not root): render the policies, then attach `jenkins-deployer-policy.json` to a dedicated deployer user. Create a second identity with `full-cleanup-policy.json` only when you intend to run `FULL_CLEANUP`.

   ```bash
   iam/render-policies.sh        # writes iam/rendered/*.json (gitignored)
   ```

2. **Local Jenkins**: see [Local Jenkins](#local-jenkins) below.

3. In Jenkins, add a *Username with password* credential with ID `aws-containerized-app-deployer` (username = access key ID, password = secret access key). `FULL_CLEANUP` additionally needs a credential with ID `aws-containerized-app-full-cleanup`; without it that stage fails and nothing is deleted.

### Offline tests

`tests/run-tests.sh` exercises every script against a stateful fake AWS CLI that also enforces the IAM policies (no AWS account or Docker needed):

```bash
python3 -m venv .venv-test && .venv-test/bin/pip install jmespath==1.0.1
tests/run-tests.sh
```

## Local Jenkins

A local Jenkins controller runs in Docker Compose (`jenkins/`) and loads this repository's `Jenkinsfile` into a ready-made Pipeline job. It is meant for a **trusted, single-user machine**.

### Prerequisites

- Windows 10/11 with WSL2 and a Linux distribution (this repository lives inside WSL, e.g. `~/projects/containerized_app`).
- Docker Desktop running, with *Settings > Resources > WSL integration* enabled for that distribution. Check from WSL: `docker info`.
- About 2 GB of free disk space for the image, and free port `8080` on localhost (or set `JENKINS_PORT`).

### What the setup contains

| File | Purpose |
| ---- | ------- |
| `jenkins/Dockerfile` | Official `jenkins/jenkins:2.580.1-lts-jdk21` image plus the Docker CLI, AWS CLI v2 and `envsubst` |
| `jenkins/plugins.txt` | The 10 plugins the pipeline needs, plus their dependencies, all pinned |
| `jenkins/init.groovy.d/10-experiment5-job.groovy` | Creates the Pipeline job on startup if it is missing; never starts a build |
| `jenkins/compose.yaml` | Service definition: named volume `jenkins_home`, Docker socket, read-only repository mount, UI on `127.0.0.1` only |
| `jenkins/start.sh` | Builds the image, detects the Docker socket's group and starts Jenkins |

- **Repository access**: the repository root is mounted read-only at `/repo`, and the job clones `file:///repo`, branch `main`. Jenkins builds **committed** history only, so commit locally (no push needed) before running a build. Uncommitted edits are invisible to Jenkins. Git's protection against local checkouts is switched off for this controller (`ALLOW_LOCAL_CHECKOUT`) for that reason.
- **Docker access**: the host's Docker socket is mounted so the `START` image build can work. This gives Jenkins **root-equivalent control of the Docker Desktop VM**: it can run any container and mount anything inside the VM. No privileged container is used, and the UI listens on `127.0.0.1` only. Never expose it beyond this machine.
- **No secrets in files**: the first login uses Jenkins' generated one-time password. AWS keys are only ever added as Jenkins credentials in the UI.

### Start Jenkins

```bash
jenkins/start.sh                       # build the image and start; UI on http://localhost:8080
JENKINS_PORT=8081 jenkins/start.sh     # if 8080 is taken
```

On the first start, unlock Jenkins at <http://localhost:8080> with the one-time password:

```bash
docker compose -f jenkins/compose.yaml exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

In the setup wizard, choose **Select plugins to install > None** (everything needed is already installed), then create your admin user.

### Run the Pipeline job

The job **experiment5-containerized-app** already exists on the dashboard. Nothing runs automatically: the job has no triggers, and startup never schedules a build.

1. Open the job and choose **Build with Parameters**.
2. Leave `ACTION=STATUS` (the default, read-only) and choose **Build**.
3. Follow the run under *Console Output* or the stage view.

Until the AWS credential `aws-containerized-app-deployer` exists in Jenkins, every action stops in the *Preflight* stage with `AWS credential 'aws-containerized-app-deployer' is not configured in Jenkins, so no AWS call was made`. No script runs. `START`, `STOP` and `FULL_CLEANUP` change real AWS resources; see [Jenkins Operations](#jenkins-operations) for their confirmations.

To clone from GitHub instead of the local mount, set `EXP5_REPO_URL` (and optionally `EXP5_REPO_BRANCH`) when starting. This only affects a newly created job; to recreate it, delete the job in the UI and restart Jenkins:

```bash
EXP5_REPO_URL=https://github.com/kush-dabade/containerized-aws-app.git jenkins/start.sh
```

### Stop, restart and reset

```bash
docker compose -f jenkins/compose.yaml stop     # stop; keeps jobs, credentials and history
jenkins/start.sh                                 # start again (data is kept)
docker compose -f jenkins/compose.yaml down     # remove the container; the jenkins_home volume is kept
```

> **Reset warning:** `docker compose -f jenkins/compose.yaml down -v` deletes the `exp5-jenkins_jenkins_home` volume: the admin user, **all Jenkins credentials (including AWS keys)**, job configuration and build history. The next `jenkins/start.sh` starts from the setup wizard and recreates the job. It does not touch any AWS resource.

### Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `docker: command not found` in WSL | Docker Desktop > *Settings > Resources > WSL integration*: enable your distribution, *Apply & restart*, then open a new WSL terminal. |
| `Cannot connect to the Docker daemon` / `Docker engine is not reachable` | Start Docker Desktop and wait until it reports *Engine running*; then `docker info` should work. If the engine is stuck, use *Troubleshoot > Restart* in Docker Desktop, or run `wsl --shutdown` from Windows and start Docker Desktop again. |
| `permission denied` on `/var/run/docker.sock` inside Jenkins | Restart through `jenkins/start.sh`, which sets `DOCKER_GID` to the socket's group. Plain `docker compose up` defaults to group `0`. |
| Port 8080 already in use | `JENKINS_PORT=8081 jenkins/start.sh`, then open `http://localhost:8081`. |
| Build fails with `Unable to find Jenkinsfile` or an old revision | Jenkins builds committed history on `main`: commit your changes, or check `EXP5_REPO_BRANCH`. |
| `Cannot use local repository` / local checkout rejected | Use `jenkins/compose.yaml` as-is; it sets `-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true`. |
| The job is missing | Restart Jenkins; the init script recreates it. Check `docker compose -f jenkins/compose.yaml logs jenkins \| grep experiment5`. |
| Slow first start | The first start unpacks plugins; `jenkins/start.sh` waits until the container's health check passes. |

## Testing

| Test                        | Result  |
| --------------------------- | ------- |
| Docker image build          | Passed  |
| Local application test      | Passed  |
| ECR image upload            | Passed  |
| ECS service deployment      | Passed  |
| Fargate task status         | RUNNING |
| HTTP test                   | 200 OK  |
| Browser test                | Passed  |

## Project Structure

```
.
├── Dockerfile
├── Jenkinsfile                      # STATUS / START / STOP / FULL_CLEANUP pipeline
├── server.js                        # Express app with / and /health
├── task-definition.template.json    # Fargate task definition (CloudWatch logging)
├── iam/
│   ├── ecs-task-trust-policy.json   # execution role trust policy
│   ├── jenkins-deployer-policy.json # least-privilege deployer policy (template)
│   ├── full-cleanup-policy.json     # ECR + role deletion only (separate identity)
│   └── render-policies.sh
├── jenkins/                         # local Jenkins: image, compose file, job init script
└── scripts/
    ├── common.sh                    # shared settings and helpers
    ├── preflight.sh
    ├── provision.sh                 # ECR, IAM role, log group, security group, cluster
    ├── build-push.sh                # build, local smoke test, push (Git SHA tag)
    ├── deploy.sh                    # task definition + service, waits for stability
    ├── smoke-test.sh                # HTTP checks against the running task
    ├── deprovision.sh               # STOP
    ├── full-cleanup.sh              # FULL_CLEANUP (ECR + role, after STOP)
    ├── verify-cleanup.sh            # fails if experiment resources remain
    └── status.sh
tests/
├── run-tests.sh                     # offline suite
└── fakes/                           # fake aws, docker, curl, sleep
```

## License

No license has been specified for this project yet.
