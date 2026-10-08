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
Security Group    (inbound TCP 3000 allowed)
   ↓
Application       (reachable at http://<task-public-ip>:3000)
```

> **Note:** The AWS resources used for this practical were terminated after testing. There is no live deployment.

## AWS Deployment

During the practical, the application was successfully deployed using:

- **Amazon ECR** to store the Docker image
- **Amazon ECS** to define and run the service
- **AWS Fargate** as the serverless launch type
- **VPC networking** (subnet with a public IP assigned to the task)
- **Security Group** allowing inbound traffic on port 3000

The application returned HTTP 200 and was accessible through a browser during testing.

Supporting files:

- `task-definition.example.json`: ECS Fargate task definition template. Replace `<AWS_ACCOUNT_ID>` and `<AWS_REGION>` with your own values before registering it.
- `ecs-task-trust-policy.json`: IAM trust policy that allows ECS tasks to assume the task execution role.

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
├── .dockerignore
├── .gitignore
├── Dockerfile
├── README.md
├── ecs-task-trust-policy.json
├── package-lock.json
├── package.json
├── server.js
└── task-definition.example.json
```

## License

No license has been specified for this project yet.
