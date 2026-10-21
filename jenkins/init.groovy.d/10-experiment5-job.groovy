// Creates the Experiment 5 Pipeline job when Jenkins starts, if it does not
// exist yet. An existing job is left untouched, so edits made in the UI
// survive restarts; delete the job and restart Jenkins to recreate it.
//
// The job loads the repository's Jenkinsfile from Git. It has no triggers and
// this script never schedules a build: every run, including the first, is
// started by hand, and the default ACTION is the read-only STATUS.
//
// Settings (environment variables, see jenkins/compose.yaml):
//   EXP5_JOB_NAME     job name     (default experiment5-containerized-app)
//   EXP5_REPO_URL     Git URL      (default file:///repo, the read-only mount)
//   EXP5_REPO_BRANCH  branch       (default main)

import hudson.model.ChoiceParameterDefinition
import hudson.model.ParametersDefinitionProperty
import hudson.model.StringParameterDefinition
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.GitSCM
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob

def env = System.getenv()
def jobName = env.EXP5_JOB_NAME ?: 'experiment5-containerized-app'
def repoUrl = env.EXP5_REPO_URL ?: 'file:///repo'
def branch = env.EXP5_REPO_BRANCH ?: 'main'
def jenkins = Jenkins.get()

if (jenkins.getItem(jobName) != null) {
  println "[experiment5] Job '${jobName}' already exists; leaving it unchanged"
  return
}

def scm = new GitSCM(GitSCM.createRepoList(repoUrl, null), [new BranchSpec("*/${branch}")], null, null, [])
def definition = new CpsScmFlowDefinition(scm, 'Jenkinsfile')
definition.lightweight = true

def job = jenkins.createProject(WorkflowJob, jobName)
job.description = "Experiment 5 lifecycle (Jenkinsfile from ${repoUrl}, branch ${branch}). " +
    'Run it with "Build with Parameters". ACTION=STATUS is read-only; START, STOP and ' +
    'FULL_CLEANUP change AWS resources and need AWS credentials configured in Jenkins.'
job.definition = definition

// Mirror the Jenkinsfile's parameters so "Build with Parameters" (default
// STATUS) is offered before the first build. Each run re-applies the
// Jenkinsfile's own definitions; tests/run-tests.sh checks that they match.
job.addProperty(new ParametersDefinitionProperty([
    new ChoiceParameterDefinition('ACTION', ['STATUS', 'START', 'STOP', 'FULL_CLEANUP'] as String[],
        'STATUS: read-only report. START, STOP and FULL_CLEANUP change AWS resources; see the Jenkinsfile.'),
    new StringParameterDefinition('ALLOWED_CIDR', '',
        'START only. IPv4 CIDR allowed to reach port 3000. Empty = this Jenkins host\'s public IP (/32).', true),
    new StringParameterDefinition('CONFIRM', '',
        'Required for destructive actions. STOP: type STOP. FULL_CLEANUP: type containerized-aws-app', true),
]))
job.save()
println "[experiment5] Created Pipeline job '${jobName}' (${repoUrl}, */${branch}); no build was scheduled"
