# Jenkins controller for Experiment 5. Adds the Docker CLI (which talks to the
# Docker Desktop engine through the mounted socket), AWS CLI v2 and envsubst,
# a pinned set of plugins, and the init script that creates the Pipeline job.
FROM jenkins/jenkins:2.580.1-lts-jdk21

ARG AWS_CLI_VERSION=2.37.7

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gettext-base unzip \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
 && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" -o /tmp/awscliv2.zip \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscliv2.zip /var/lib/apt/lists/*

# The repository mount is owned by the host user; let Git read it whatever its UID.
RUN git config --system --add safe.directory /repo \
 && git config --system --add safe.directory /repo/.git
USER jenkins

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# ".override" makes the entrypoint replace the copy in JENKINS_HOME on every
# start, so image updates to the script take effect on existing volumes.
COPY --chown=jenkins:jenkins init.groovy.d/10-experiment5-job.groovy \
     /usr/share/jenkins/ref/init.groovy.d/10-experiment5-job.groovy.override
