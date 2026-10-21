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

2. **Jenkins in Docker** (needs Docker Desktop with WSL integration):

   ```bash
   jenkins/start.sh              # http://localhost:8080
   ```

3. In Jenkins, add a *Username with password* credential with ID `aws-containerized-app-deployer` (username = access key ID, password = secret access key), then create a *Pipeline* job using *Pipeline script from SCM* pointing at this repository's `Jenkinsfile`. `FULL_CLEANUP` additionally needs a credential with ID `aws-containerized-app-full-cleanup`; without it that stage fails and nothing is deleted.

### Offline tests

`tests/run-tests.sh` exercises every script against a stateful fake AWS CLI that also enforces the IAM policies (no AWS account or Docker needed):

```bash
python3 -m venv .venv-test && .venv-test/bin/pip install jmespath==1.0.1
tests/run-tests.sh
```

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
├── jenkins/                         # Jenkins controller image + compose file
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
