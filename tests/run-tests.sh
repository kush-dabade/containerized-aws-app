#!/usr/bin/env bash
# check() evaluates its single-quoted condition later, so variables are read
# there rather than where ShellCheck can see them.
# shellcheck disable=SC2016,SC2034
# Offline test suite for the Experiment 5 scripts. Nothing here talks to AWS
# or Docker: tests/fakes/ stands in for aws, docker, curl and sleep, and the
# fake aws enforces the rendered IAM policies at the action level.
#
# Requires python3 with jmespath. Either have it on PATH or create a venv:
#   python3 -m venv .venv-test && .venv-test/bin/pip install jmespath==1.0.1
#
#   tests/run-tests.sh            (TEST_VENV=/path/to/venv to use another venv)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_VENV="${TEST_VENV:-$REPO/.venv-test}"
[[ -x "$TEST_VENV/bin/python3" ]] && PATH="$TEST_VENV/bin:$PATH"
python3 -c 'import jmespath' 2>/dev/null || {
  echo "python3 with jmespath is required; see the header of $0" >&2
  exit 2
}

TMP="$(mktemp -d)"
PROBE="$REPO/.test-dirty-probe"
cleanup() { rm -rf "$TMP" "$PROBE" "$REPO/app-url.txt"; }
trap cleanup EXIT

export PATH="$REPO/tests/fakes:$PATH"
export MOCK_STATE="$TMP/state.json" MOCK_LOG="$TMP/calls.log"
unset AWS_ACCOUNT_ID ALLOWED_CIDR IMAGE_TAG GIT_COMMIT MOCK_FAIL MOCK_ARN MOCK_POLICY

DEPLOYER="$TMP/policies/jenkins-deployer-policy.json"
CLEANUP="$TMP/policies/full-cleanup-policy.json"
OUT="$TMP/out.txt"
pass=0
fail=0

ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); [[ -s "$OUT" ]] && sed 's/^/          /' "$OUT" | tail -12; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# run [VAR=value...] command...: run in the repo with a fresh call log.
run() { : >"$MOCK_LOG"; (cd "$REPO" && env "$@") >"$OUT" 2>&1; }
calls() { grep -cE "$1" "$MOCK_LOG"; }
said() { grep -qF -- "$1" "$OUT"; }

state_reset() {
  echo '{"repos":{},"roles":{},"logs":{},"sgs":{},"clusters":{},"tds":{},"services":{},"tasks":{},"seq":0,"sg_busy":0}' >"$MOCK_STATE"
}
# mutate 'python statements on s': edit the fake account's state.
mutate() { python3 -c "import json; p='$MOCK_STATE'; s=json.load(open(p)); $1; json.dump(s, open(p, 'w'))"; }
query() { python3 -c "import json; s=json.load(open('$MOCK_STATE')); print($1)"; }

TD_ARN=arn:aws:ecs:ap-south-1:123456789012:task-definition
add_td() { mutate "s['tds']['$1']={'arn':'$TD_ARN/$1','status':'$2','image':'x'}"; }
add_sg() { # id name vpc tagged(True/False)
  mutate "s['sgs']['$1']={'GroupId':'$1','GroupName':'$2','VpcId':'$3','IpPermissions':[],'Tags':[{'Key':'Project','Value':'containerized-aws-app'}] if $4 else []}"
}
start_all() { run MOCK_POLICY="$DEPLOYER" IMAGE_TAG="${1:-aaaaaaaaaaaa}" bash -c \
  'bash scripts/provision.sh && bash scripts/build-push.sh && bash scripts/deploy.sh && bash scripts/smoke-test.sh'; }

# ---------------------------------------------------------------------------
echo "== Static checks"
syntax_ok=true
for f in "$REPO"/scripts/*.sh "$REPO"/iam/render-policies.sh "$REPO"/jenkins/start.sh "$REPO"/tests/run-tests.sh; do
  bash -n "$f" || syntax_ok=false
done
check "bash -n on every script" '$syntax_ok'

run AWS_ACCOUNT_ID=123456789012 DEFAULT_VPC_ID=vpc-0default00000000 RENDER_OUT_DIR="$TMP/policies" bash iam/render-policies.sh
check "IAM templates render within the size limit" '[[ $? == 0 ]] || false'
[[ -f "$DEPLOYER" && -f "$CLEANUP" ]] || { echo "cannot continue without rendered policies"; exit 1; }
run bash -c 'source scripts/common.sh; export AWS_ACCOUNT_ID=123456789012 EXEC_ROLE_ARN=arn:aws:iam::123456789012:role/r IMAGE_URI=i:t; render_template task-definition.template.json'
cp "$OUT" "$TMP/td.json"
check "rendered task definition, IAM policies and trust policy are valid JSON" \
  'python3 -c "import json,sys; [json.load(open(f)) for f in sys.argv[1:]]" "$TMP/td.json" "$TMP"/policies/*.json'

# Issue 1: lookups must never be evaluated where bash discards their failure.
masked="$(grep -nE '(\[\[|<<<|for [a-z_]+ in ).*\$\((aws|aws_text|cluster_status|service_status|wait_for_cluster_settled|security_group_id|unowned_security_group_ids|project_security_group_ids|default_vpc_id|default_subnet_ids|task_definition_arns|git)[ )]' \
  "$REPO"/scripts/*.sh "$REPO"/iam/render-policies.sh)"
check "no AWS/git lookup inside [[ ]], a here-string or a for-list" '[[ -z "$masked" ]] || { echo "$masked" >"$OUT"; false; }'

# Issue 5: deletion permissions live only in the full-cleanup policy.
actions() { python3 -c "import json,sys; print(' '.join(sorted({a for s in json.load(open(sys.argv[1]))['Statement'] for a in ([s['Action']] if isinstance(s['Action'],str) else s['Action'])})))" "$1"; }
deployer_actions="$(actions "$DEPLOYER")"
cleanup_actions="$(actions "$CLEANUP")"
check "deployer policy has no ecr:DeleteRepository, iam:DeleteRole or iam:DetachRolePolicy" \
  '[[ " $deployer_actions " != *" ecr:DeleteRepository "* && " $deployer_actions " != *" iam:DeleteRole "* && " $deployer_actions " != *" iam:DetachRolePolicy "* ]]'
check "full-cleanup policy holds exactly those deletes plus read-only lookups" \
  '[[ "$cleanup_actions" == "ecr:DeleteRepository ecr:DescribeImages ecr:DescribeRepositories ecs:DescribeClusters iam:DeleteRole iam:DetachRolePolicy iam:GetRole iam:ListAttachedRolePolicies" ]]'

# ---------------------------------------------------------------------------
echo "== Issue 1: aws_text runs the CLI once and never turns an error into empty"
COUNT_BIN="$TMP/count-bin"
mkdir -p "$COUNT_BIN"
cat >"$COUNT_BIN/aws" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$COUNT_LOG"
[[ "${COUNT_FAIL:-}" == 1 ]] && { echo "An error occurred (ThrottlingException)" >&2; exit 254; }
echo "sg-0123456789"
EOF
chmod +x "$COUNT_BIN/aws"
for mode in success failure; do
  : >"$TMP/count.log"
  (cd "$REPO" && PATH="$COUNT_BIN:$PATH" COUNT_LOG="$TMP/count.log" COUNT_FAIL=$([[ $mode == failure ]] && echo 1) \
    bash -c 'source scripts/common.sh; id="$(aws_text ec2 create-security-group --group-name t --query GroupId)"; echo "result=[$id]"') >"$OUT" 2>&1
  rc=$?
  n="$(wc -l <"$TMP/count.log")"
  if [[ $mode == success ]]; then
    check "mutating call on success: executed once, output returned" '[[ $n == 1 && $rc == 0 ]] && said "result=[sg-0123456789]"'
  else
    check "mutating call on failure: executed once, non-zero exit, no empty result" '[[ $n == 1 && $rc != 0 ]] && ! said "result=["'
  fi
done

state_reset
run MOCK_POLICY="$DEPLOYER" MOCK_FAIL=ecs:describe-clusters bash scripts/provision.sh
check "describe-clusters error fails provision without calling create-cluster" '[[ $? != 0 && $(calls "^ecs create-cluster") == 0 ]]'
state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE','failure_reason':'Throttled'}"
run bash -c 'source scripts/common.sh; s="$(cluster_status)"; echo "status=[$s]"'
check "cluster lookup failure other than MISSING is fatal, not 'absent'" '[[ $? != 0 ]] && ! said "status=["'

# ---------------------------------------------------------------------------
echo "== Guards"
state_reset
run MOCK_ARN=arn:aws:iam::123456789012:root bash scripts/status.sh
check "root identity refused" '[[ $? == 1 ]] && said "root user"'
run bash scripts/deprovision.sh
check "STOP refused without CONFIRM_STOP=yes, before any AWS call" '[[ $? == 1 && $(calls .) == 0 ]]'
run CONFIRM_FULL_CLEANUP=yes bash scripts/full-cleanup.sh
check "FULL_CLEANUP refused with the wrong confirmation" '[[ $? == 1 && $(calls .) == 0 ]]'
run ALLOWED_CIDR=10.0.0.0/33 bash scripts/provision.sh
check "invalid ALLOWED_CIDR rejected" '[[ $? == 1 ]]'

# ---------------------------------------------------------------------------
echo "== Lifecycle under the deployer policy"
state_reset
add_td containerized-aws-task:1 ACTIVE
add_td containerized-aws-task-other:1 ACTIVE
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "first STOP succeeds on the near-empty account" '[[ $? == 0 ]]'
check "leftover containerized-aws-task:1 deregistered and deleted" '[[ $(query "s[\"tds\"][\"containerized-aws-task:1\"][\"status\"]") == DELETE_IN_PROGRESS ]]'
check "other family sharing the name prefix untouched" '[[ $(query "s[\"tds\"][\"containerized-aws-task-other:1\"][\"status\"]") == ACTIVE ]]'
run MOCK_POLICY="$DEPLOYER" bash scripts/verify-cleanup.sh
check "verify-cleanup passes after the first STOP" '[[ $? == 0 ]] && said "Cleanup verified"'

touch "$PROBE"
run MOCK_POLICY="$DEPLOYER" bash scripts/build-push.sh
check "build-push refuses a dirty working tree without IMAGE_TAG" '[[ $? == 1 ]] && said "uncommitted changes"'
rm -f "$PROBE"

start_all aaaaaaaaaaaa
check "START: provision, build, push, deploy, smoke test" '[[ $? == 0 ]]'
check "security group ingress is the detected public IP /32" \
  '[[ $(query "[p[\"IpRanges\"] for g in s[\"sgs\"].values() for p in g[\"IpPermissions\"]]") == "[[{'"'"'CidrIp'"'"': '"'"'203.0.113.7/32'"'"'}]]" ]]'
check "log group retention is 1 day" '[[ $(query "s[\"logs\"][\"/ecs/containerized-aws-task\"][\"retention\"]") == 1 ]]'
check "ECR repository is immutable with a lifecycle policy" '[[ $(query "s[\"repos\"][\"containerized-aws-app\"][\"mutability\"], s[\"repos\"][\"containerized-aws-app\"][\"lifecycle\"]") == "IMMUTABLE True" ]]'
check "image pushed with the commit tag" '[[ $(query "s[\"repos\"][\"containerized-aws-app\"][\"images\"]") == "['"'"'aaaaaaaaaaaa'"'"']" ]]'
check "app-url.txt written by the smoke test" '[[ $(cat "$REPO/app-url.txt") == http://198.51.100.20:3000 ]]'

run MOCK_POLICY="$DEPLOYER" ALLOWED_CIDR=198.51.100.0/24 bash scripts/provision.sh
check "START re-run: no duplicate creates" '[[ $? == 0 && $(calls "create-(repository|role|log-group|security-group|cluster)") == 0 ]]'
check "START re-run: ingress re-synced to the new ALLOWED_CIDR" \
  '[[ $(calls "revoke-security-group-ingress.*203.0.113.7/32") == 1 && $(calls "authorize-security-group-ingress.*198.51.100.0/24") == 1 ]]'
run MOCK_POLICY="$DEPLOYER" IMAGE_TAG=aaaaaaaaaaaa bash scripts/build-push.sh
check "existing image tag reused, not rebuilt" '[[ $? == 0 && $(calls "^docker build") == 0 ]]'
run MOCK_POLICY="$DEPLOYER" IMAGE_TAG=bbbbbbbbbbbb bash -c 'bash scripts/build-push.sh && bash scripts/deploy.sh'
check "new commit updates the existing service" '[[ $? == 0 && $(calls "^ecs update-service") == 1 && $(calls "^ecs create-service") == 0 ]]'
run MOCK_POLICY="$DEPLOYER" bash scripts/status.sh
check "status reports the running, billable task" '[[ $? == 0 ]] && said "BILLING"'

mutate "s['sg_busy']=2"
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "STOP succeeds while the task's network interface is still releasing" '[[ $? == 0 && $(calls "^ec2 delete-security-group") == 3 ]]'
run MOCK_POLICY="$DEPLOYER" bash scripts/verify-cleanup.sh
check "verify-cleanup passes after STOP and reports ECR images kept" '[[ $? == 0 ]] && said "KEPT  ECR repository containerized-aws-app with 2 image(s)"'
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "STOP re-run is a no-op" '[[ $? == 0 && $(calls "delete|deregister") == 0 ]]'
start_all bbbbbbbbbbbb
check "START again from the preserved ECR image" '[[ $? == 0 && $(calls "^docker build") == 0 ]]'

# ---------------------------------------------------------------------------
echo "== Issue 2: transitional cluster states"
state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE','pending':['PROVISIONING','PROVISIONING']}"
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "PROVISIONING cluster: STOP waits, then deletes it" \
  '[[ $? == 0 && $(calls "^ecs delete-cluster") == 1 ]] && said "is PROVISIONING"'

state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'INACTIVE','pending':['DEPROVISIONING']}"
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "DEPROVISIONING cluster: STOP waits until it is INACTIVE" \
  '[[ $? == 0 && $(calls "^ecs delete-cluster") == 0 ]] && said "is DEPROVISIONING" && said "already gone (status: INACTIVE)"'

state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'INACTIVE','pending':['DEPROVISIONING']*5}"
run MOCK_POLICY="$DEPLOYER" CLUSTER_WAIT_ATTEMPTS=3 CONFIRM_STOP=yes bash scripts/deprovision.sh
check "cluster stuck DEPROVISIONING: STOP fails and does not report success" \
  '[[ $? != 0 ]] && said "still DEPROVISIONING after 3 checks" && ! said "Runtime resources deleted"'

state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'FAILED'}"
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "FAILED cluster: STOP fails explicitly" '[[ $? != 0 ]] && said "in state FAILED" && ! said "Runtime resources deleted"'

state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE'}; s['delete_pending']=['DEPROVISIONING','DEPROVISIONING']"
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "cluster DEPROVISIONING after delete-cluster: STOP waits for INACTIVE" '[[ $? == 0 ]] && said "deleted (status: INACTIVE)"'

state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'INACTIVE','pending':['DEPROVISIONING']*5}"
run MOCK_POLICY="$DEPLOYER" CLUSTER_WAIT_ATTEMPTS=3 bash scripts/provision.sh
check "START does not create a cluster over one that is still DEPROVISIONING" '[[ $? != 0 && $(calls "^ecs create-cluster") == 0 ]]'

state_reset
mutate "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE','pending':['PROVISIONING']}"
run MOCK_POLICY="$DEPLOYER" bash scripts/verify-cleanup.sh
check "verify-cleanup fails on a transitional cluster" '[[ $? != 0 ]] && said "status PROVISIONING"'

# ---------------------------------------------------------------------------
echo "== Issue 3: security group ownership"
VPC=vpc-0default00000000
state_reset
add_sg sg-0untagged containerized-app-sg $VPC False
run MOCK_POLICY="$DEPLOYER" bash scripts/provision.sh
check "untagged group with the same name: START refuses, creates nothing" \
  '[[ $? != 0 && $(calls "create-security-group|authorize-security-group-ingress") == 0 ]] && said "without tag Project=containerized-aws-app (sg-0untagged)"'
run bash -c "source scripts/common.sh; id=\"\$(security_group_id $VPC)\"; echo \"id=[\$id]\""
check "security_group_id ignores the untagged group" '[[ $? == 0 ]] && said "id=[]"'

state_reset
add_sg sg-0first containerized-app-sg $VPC True
add_sg sg-0second containerized-app-sg $VPC True
run bash -c "source scripts/common.sh; id=\"\$(security_group_id $VPC)\"; echo \"id=[\$id]\""
check "two tagged matches are rejected as ambiguous" '[[ $? != 0 ]] && said "Ambiguous: 2 security groups" && ! said "id=["'
run MOCK_POLICY="$DEPLOYER" bash scripts/provision.sh
check "provision stops on the ambiguous match" '[[ $? != 0 && $(calls "authorize-security-group-ingress|revoke-security-group-ingress") == 0 ]]'

state_reset
add_sg sg-0mine containerized-app-sg $VPC True
add_sg sg-0othervpc containerized-app-sg vpc-0other0000000000 True
run bash -c "source scripts/common.sh; id=\"\$(security_group_id $VPC)\"; echo \"id=[\$id]\""
check "a tagged group in another VPC is not selected" '[[ $? == 0 ]] && said "id=[sg-0mine]"'
add_sg sg-0foreign containerized-app-sg vpc-0third0000000000 False
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "STOP deletes every project-tagged group and never the untagged one" \
  '[[ $? == 0 && $(query "sorted(s[\"sgs\"])") == "['"'"'sg-0foreign'"'"']" ]]'

# ---------------------------------------------------------------------------
echo "== Issue 4: verify-cleanup checks real absence and fails on lookup errors"
seed_clean() { state_reset; mutate "s['repos']['containerized-aws-app']={'images':['x'],'mutability':'IMMUTABLE','lifecycle':True}"; }
expect_remaining() { # description, text the REMAINING report must contain, mutate expression
  seed_clean
  mutate "$3"
  run MOCK_POLICY="$DEPLOYER" bash scripts/verify-cleanup.sh
  rc=$?
  expected="$2"
  check "fails when $1 remains, and names it" \
    '[[ $rc != 0 ]] && grep "REMAINING" "$OUT" | grep -qF -- "$expected" && ! said "Cleanup verified"'
}
seed_clean
run MOCK_POLICY="$DEPLOYER" bash scripts/verify-cleanup.sh
check "passes on a clean account (ECR kept by design)" '[[ $? == 0 ]] && said "Cleanup verified"'
expect_remaining "an ACTIVE cluster" "ECS cluster containerized-aws-cluster (status ACTIVE)" "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE'}"
expect_remaining "a DRAINING service" "ECS service containerized-aws-service (status DRAINING)" \
  "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE'}; s['services']['containerized-aws-cluster/containerized-aws-service']={'status':'DRAINING','desired':0,'td':'t'}"
expect_remaining "a task that is still stopping" "ECS task t1 (status DEPROVISIONING)" \
  "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE'}; s['tasks']['t1']={'arn':'arn:aws:ecs:ap-south-1:123456789012:task/containerized-aws-cluster/t1','cluster':'containerized-aws-cluster','service':'containerized-aws-service','td':'t','lastStatus':'DEPROVISIONING','desiredStatus':'STOPPED'}"
expect_remaining "an ACTIVE task definition" "Task definition containerized-aws-task:7 (ACTIVE)" \
  "s['tds']['containerized-aws-task:7']={'arn':'$TD_ARN/containerized-aws-task:7','status':'ACTIVE','image':'x'}"
expect_remaining "an INACTIVE (undeleted) task definition" "Task definition containerized-aws-task:7 (INACTIVE" \
  "s['tds']['containerized-aws-task:7']={'arn':'$TD_ARN/containerized-aws-task:7','status':'INACTIVE','image':'x'}"
expect_remaining "the log group" "Log group /ecs/containerized-aws-task" "s['logs']['/ecs/containerized-aws-task']={'retention':1}"
expect_remaining "a project-tagged security group in a non-default VPC" "Security group sg-0x" \
  "s['sgs']['sg-0x']={'GroupId':'sg-0x','GroupName':'anything','VpcId':'vpc-0other0000000000','IpPermissions':[],'Tags':[{'Key':'Project','Value':'containerized-aws-app'}]}"
seed_clean
mutate "s['tds']['containerized-aws-task:7']={'arn':'$TD_ARN/containerized-aws-task:7','status':'DELETE_IN_PROGRESS','image':'x'}"
run MOCK_POLICY="$DEPLOYER" bash scripts/verify-cleanup.sh
check "passes with revisions in DELETE_IN_PROGRESS" '[[ $? == 0 ]]'

for op in ecs:describe-clusters ecs:list-task-definitions ec2:describe-security-groups logs:describe-log-groups ecr:describe-repositories iam:get-role; do
  seed_clean
  run MOCK_POLICY="$DEPLOYER" MOCK_FAIL=$op bash scripts/verify-cleanup.sh
  check "fails when $op errors" '[[ $? != 0 ]] && ! said "Cleanup verified"'
done
for op in ecs:describe-services ecs:list-tasks ecs:describe-tasks; do
  seed_clean
  mutate "s['clusters']['containerized-aws-cluster']={'status':'ACTIVE'}; s['tasks']['t1']={'arn':'arn:aws:ecs:ap-south-1:123456789012:task/containerized-aws-cluster/t1','cluster':'containerized-aws-cluster','service':'x','td':'t','lastStatus':'RUNNING','desiredStatus':'RUNNING'}"
  run MOCK_POLICY="$DEPLOYER" MOCK_FAIL=$op bash scripts/verify-cleanup.sh
  check "fails when $op errors" '[[ $? != 0 ]] && ! said "Cleanup verified"'
done

# ---------------------------------------------------------------------------
echo "== Issue 5: FULL_CLEANUP needs the separate identity"
start_all aaaaaaaaaaaa >/dev/null
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
run MOCK_POLICY="$DEPLOYER" CONFIRM_FULL_CLEANUP=containerized-aws-app bash scripts/full-cleanup.sh
check "deployer identity is denied ecr:DeleteRepository; repository intact" \
  '[[ $? != 0 ]] && said "not authorized to perform: ecr:DeleteRepository" && [[ $(query "\"containerized-aws-app\" in s[\"repos\"]") == True ]]'
start_all aaaaaaaaaaaa >/dev/null
run MOCK_POLICY="$CLEANUP" CONFIRM_FULL_CLEANUP=containerized-aws-app bash scripts/full-cleanup.sh
check "full-cleanup refuses while the cluster still exists" '[[ $? != 0 && $(calls "delete-repository|delete-role") == 0 ]] && said "run STOP"'
run MOCK_POLICY="$DEPLOYER" CONFIRM_STOP=yes bash scripts/deprovision.sh
run MOCK_POLICY="$CLEANUP" CONFIRM_STOP=yes bash scripts/deprovision.sh
check "full-cleanup identity cannot run STOP (no runtime permissions)" '[[ $? != 0 ]] && said "not authorized"'
run MOCK_POLICY="$CLEANUP" CONFIRM_FULL_CLEANUP=containerized-aws-app bash scripts/full-cleanup.sh
check "full-cleanup identity deletes the repository and the role after STOP" '[[ $? == 0 ]]'
run MOCK_POLICY="$DEPLOYER" bash scripts/verify-cleanup.sh --full
check "verify --full passes (deployer identity)" '[[ $? == 0 ]] && said "Cleanup verified"'
run MOCK_POLICY="$CLEANUP" CONFIRM_FULL_CLEANUP=containerized-aws-app bash scripts/full-cleanup.sh
check "full-cleanup re-run is safe" '[[ $? == 0 ]]'

echo
echo "RESULT: $pass passed, $fail failed"
((fail == 0))
