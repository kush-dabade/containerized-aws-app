// Experiment 5: containerized application on Amazon ECS (Fargate).
// One parameterized job drives the whole lifecycle; the default ACTION is the
// read-only STATUS so an accidental "Build" never changes anything.

// Runs body with AWS keys from a Jenkins "Username with password" credential.
def withAws(String credentialsId, Closure body) {
  withCredentials([usernamePassword(credentialsId: credentialsId,
                                    usernameVariable: 'AWS_ACCESS_KEY_ID',
                                    passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
    body()
  }
}

pipeline {
  agent any

  parameters {
    choice(name: 'ACTION', choices: ['STATUS', 'START', 'STOP', 'FULL_CLEANUP'],
           description: '''STATUS: read-only report of all experiment resources.
START: provision infrastructure, build and push the image, deploy to ECS, smoke test.
STOP: delete the ECS service, cluster, task definitions, log group and security group. Keeps ECR images.
FULL_CLEANUP: STOP, then (after an interactive approval, with the separate full-cleanup credential) delete the ECR repository, ALL images and the execution role.''')
    string(name: 'ALLOWED_CIDR', defaultValue: '', trim: true,
           description: 'START only. IPv4 CIDR allowed to reach port 3000. Leave empty to allow only this Jenkins host\'s public IP (/32).')
    string(name: 'CONFIRM', defaultValue: '', trim: true,
           description: 'Required for destructive actions. STOP: type STOP. FULL_CLEANUP: type containerized-aws-app')
  }

  options {
    disableConcurrentBuilds()
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  environment {
    AWS_REGION = 'ap-south-1'
    AWS_DEFAULT_REGION = 'ap-south-1'
    AWS_PAGER = ''
    // Normal deployer identity: cannot delete the ECR repository or the role.
    DEPLOYER_CREDENTIALS_ID = 'aws-containerized-app-deployer'
    // Separate identity with iam/full-cleanup-policy.json, used only by FULL_CLEANUP.
    FULL_CLEANUP_CREDENTIALS_ID = 'aws-containerized-app-full-cleanup'
  }

  stages {
    stage('Validate') {
      steps {
        script {
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.ACTION}"
          if (params.ACTION == 'STOP' && params.CONFIRM != 'STOP') {
            error('STOP deletes AWS resources. Re-run with CONFIRM=STOP.')
          }
          if (params.ACTION == 'FULL_CLEANUP' && params.CONFIRM != 'containerized-aws-app') {
            error('FULL_CLEANUP deletes the ECR repository and all images. Re-run with CONFIRM=containerized-aws-app.')
          }
        }
      }
    }

    stage('Preflight') {
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          sh "bash scripts/preflight.sh ${params.ACTION == 'START' ? '--docker' : ''}"
        }
      }
    }

    stage('Provision infrastructure') {
      when { expression { params.ACTION == 'START' } }
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          withEnv(["ALLOWED_CIDR=${params.ALLOWED_CIDR}"]) {
            sh 'bash scripts/provision.sh'
          }
        }
      }
    }

    stage('Build and push image') {
      when { expression { params.ACTION == 'START' } }
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          sh 'bash scripts/build-push.sh'
        }
      }
    }

    stage('Deploy to ECS') {
      when { expression { params.ACTION == 'START' } }
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          sh 'bash scripts/deploy.sh'
        }
      }
    }

    stage('Smoke test') {
      when { expression { params.ACTION == 'START' } }
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          sh 'bash scripts/smoke-test.sh'
        }
      }
    }

    stage('Delete runtime resources') {
      when { expression { params.ACTION in ['STOP', 'FULL_CLEANUP'] } }
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          withEnv(['CONFIRM_STOP=yes']) {
            sh 'bash scripts/deprovision.sh'
          }
        }
      }
    }

    stage('Verify cleanup') {
      when { expression { params.ACTION in ['STOP', 'FULL_CLEANUP'] } }
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          sh 'bash scripts/verify-cleanup.sh'
        }
      }
    }

    stage('Approve ECR deletion') {
      when { expression { params.ACTION == 'FULL_CLEANUP' } }
      steps {
        timeout(time: 10, unit: 'MINUTES') {
          input message: 'Permanently delete ECR repository containerized-aws-app with ALL images, and the execution role?',
                ok: 'Delete permanently'
        }
      }
    }

    stage('Delete ECR repository and role') {
      when { expression { params.ACTION == 'FULL_CLEANUP' } }
      steps {
        withAws(env.FULL_CLEANUP_CREDENTIALS_ID) {
          withEnv(["CONFIRM_FULL_CLEANUP=${params.CONFIRM}"]) {
            sh 'bash scripts/full-cleanup.sh'
          }
        }
      }
    }

    stage('Verify full cleanup') {
      when { expression { params.ACTION == 'FULL_CLEANUP' } }
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          sh 'bash scripts/verify-cleanup.sh --full'
        }
      }
    }

    stage('Status') {
      steps {
        withAws(env.DEPLOYER_CREDENTIALS_ID) {
          sh 'bash scripts/status.sh'
        }
      }
    }
  }

  post {
    success {
      script {
        if (params.ACTION == 'START' && fileExists('app-url.txt')) {
          def url = readFile('app-url.txt').trim()
          currentBuild.description = url
          archiveArtifacts artifacts: 'app-url.txt'
          echo "Application URL: ${url}  (billing until you run ACTION=STOP)"
        }
      }
    }
    failure {
      script {
        if (params.ACTION == 'START') {
          echo 'START failed part-way. Some resources may exist and bill (a Fargate task, its public IP). Review the Status output, then run ACTION=STOP.'
        }
      }
    }
  }
}
