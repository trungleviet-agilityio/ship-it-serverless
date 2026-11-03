#!/usr/bin/env bash
# Self-tests of the CI helper scripts: the plan summary, the destroy plan guard, tf/init and the plan role guardrails.
# Run by scripts/ci/selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- tf/plan-summary.sh
good_plan='{"resource_changes":[
 {"address":"module.app_ecs.aws_vpc.this","change":{"actions":["create"]}},
 {"address":"module.app_ecs.aws_lb.this","change":{"actions":["delete","create"]}},
 {"address":"module.app_ecs.aws_ecr_repository.app","change":{"actions":["delete"]}},
 {"address":"module.app_ecs.aws_route.internet","change":{"actions":["no-op"]}}]}'
# The default heading follows ENV, so the runs below start from an unset ENV (the dev default).
out="$(printf '%s' "$good_plan" | env -u ENV "$ROOT/scripts/tf/plan-summary.sh")"
case "$out" in
  *"Add 1, change 0, destroy 1, replace 1."*"| REPLACE | \`module.app_ecs.aws_lb.this\` |"*"| DELETE |"*) ok "plan summary counts and flags" ;;
  *) die "selftest: unexpected plan summary: $out" ;;
esac
case "$out" in
  *aws_route.internet*) die "selftest: no-op change must not be listed" ;;
esac
leak_plan="{\"resource_changes\":[{\"address\":\"aws_iam_role.x-${leak_id}\",\"change\":{\"actions\":[\"create\"]}}]}"
# shellcheck disable=SC2016  # the inner script is meant to expand in the child shell
expect_fail "plan summary with a 12-digit run" "12-digit" bash -c 'printf "%s" "$1" | "$2"' _ "$leak_plan" "$ROOT/scripts/tf/plan-summary.sh"

# --title changes only the heading.
titled="$(printf '%s' "$good_plan" | "$ROOT/scripts/tf/plan-summary.sh" --title "Terraform destroy plan (dev)")"
[ "$(printf '%s\n' "$titled" | head -n1)" = "### Terraform destroy plan (dev)" ] || die "selftest: --title did not set the heading"
[ "$(printf '%s\n' "$titled" | tail -n +2)" = "$(printf '%s\n' "$out" | tail -n +2)" ] || die "selftest: --title changed more than the heading"
[ "$(printf '%s\n' "$out" | head -n1)" = "### Terraform plan (dev)" ] || die "selftest: the default heading changed"
[ "$(printf '%s' "$good_plan" | ENV=prod "$ROOT/scripts/tf/plan-summary.sh" | head -n1)" = "### Terraform plan (prod)" ] \
  || die "selftest: the default heading must follow ENV"
ok "plan summary --title replaces the heading only"
expect_fail "plan summary with an unknown option" "usage:" "$ROOT/scripts/tf/plan-summary.sh" --heading x
expect_fail "plan summary with --title and no text" "usage:" "$ROOT/scripts/tf/plan-summary.sh" --title

# --- tf/destroy-check.sh
# destroy_plan <actions json> <address>...: a plan with one change per address.
destroy_plan() {
  local actions="$1" a rows=""
  shift
  for a in "$@"; do rows="${rows:+$rows,}{\"address\":\"$a\",\"change\":{\"actions\":$actions}}"; done
  printf '{"resource_changes":[%s]}' "$rows"
}
destroy_check() { printf '%s' "$1" | "$ROOT/scripts/tf/destroy-check.sh"; }
[ "$(destroy_check "$(destroy_plan '["delete"]' module.app_ecs.aws_vpc.this 'module.app_ecs.aws_lb.this[0]' module.app_ecs.module.x.aws_s3_bucket.y)")" = "3" ] \
  || die "selftest: tf/destroy-check must count the deletes under module.app_ecs."
[ "$(destroy_check '{"resource_changes":[]}')" = "0" ] || die "selftest: an empty resource_changes must count 0"
[ "$(destroy_check '{}')" = "0" ] || die "selftest: a plan without resource_changes must count 0"
mixed="$(printf '%s' "$(destroy_plan '["delete"]' module.app_ecs.aws_vpc.this)" | jq -c '.resource_changes += [
  {"address":"module.app_ecs.aws_route.r","change":{"actions":["no-op"]}},
  {"address":"data.aws_x.y","change":{"actions":["read"]}}]')"
[ "$(destroy_check "$mixed")" = "1" ] || die "selftest: no-op and read entries must be ignored"
ok "tf/destroy-check counts deletes and ignores no-op and read"
expect_fail "destroy plan with a create" "module.app_ecs.aws_vpc.this (create)" destroy_check "$(destroy_plan '["create"]' module.app_ecs.aws_vpc.this)"
expect_fail "destroy plan with an update" "module.app_ecs.aws_vpc.this (update)" destroy_check "$(destroy_plan '["update"]' module.app_ecs.aws_vpc.this)"
expect_fail "destroy plan with a replace" "module.app_ecs.aws_vpc.this (delete+create)" destroy_check "$(destroy_plan '["delete","create"]' module.app_ecs.aws_vpc.this)"
expect_fail "destroy plan with a forget" "module.app_ecs.aws_vpc.this (forget)" destroy_check "$(destroy_plan '["forget"]' module.app_ecs.aws_vpc.this)"
expect_fail "destroy plan deleting outside the module" "outside module.app_ecs.: aws_s3_bucket.x" destroy_check "$(destroy_plan '["delete"]' aws_s3_bucket.x)"
expect_fail "destroy plan deleting a lookalike module" "outside module.app_ecs.: module.app_ecs_other.aws_vpc.this" destroy_check "$(destroy_plan '["delete"]' module.app_ecs_other.aws_vpc.this)"

# Actions run code on apply: a plan that invokes any is refused, even when every resource change is a delete.
with_actions="$(destroy_plan '["delete"]' module.app_ecs.aws_vpc.this | jq -c '.action_invocations = [{"address":"action.x.y"}]')"
expect_fail "destroy plan with an action invocation" "invokes 1 action" destroy_check "$with_actions"
[ "$(destroy_check "$(destroy_plan '["delete"]' module.app_ecs.aws_vpc.this | jq -c '.action_invocations = []')")" = "1" ] \
  || die "selftest: an empty action_invocations list must pass"

# --- tf/init.sh (stub terraform: arguments are logged, nothing runs). ENV is the single key.
# tf_init_as <env> <account> <region> [args...]; tf_init <env> is the same with the valid account and region.
tf_init_as() {
  local e="$1" a="$2" r="$3"
  shift 3
  stubbed env ENV="$e" ACCOUNT="$a" REGION="$r" "$ROOT/scripts/tf/init.sh" "$@"
}
tf_init() { tf_init_as "$1" "$acct" ap-southeast-1; }
stub_reset
tf_init dev >/dev/null 2>&1 || die "selftest: tf/init of envs/dev failed"
[ "$(cat "$sd/calls")" = "$(printf '%s\n%s' \
  "terraform -chdir=infra/terraform/envs/dev init -input=false -lockfile=readonly -backend-config=bucket=sis-dev-tfstate-${acct}-ap-southeast-1-an" \
  "terraform -chdir=infra/terraform/envs/dev validate -no-color")" ] || die "selftest: tf/init ran: $(cat "$sd/calls")"
out="$(tf_init dev 2>&1)"
case "$out" in *"$acct"*) die "selftest: tf/init printed the account ID" ;; esac
ok "tf/init derives the root and the bucket from ENV, inits with a read-only lock file, then validates"
stub_reset
tf_init prod >/dev/null 2>&1 || die "selftest: tf/init of envs/prod failed"
calls_have "-chdir=infra/terraform/envs/prod init" || die "selftest: tf/init did not derive the prod root"
calls_have "bucket=sis-prod-tfstate-${acct}-ap-southeast-1-an" || die "selftest: tf/init did not derive the prod bucket"
stub_reset
for bad_env in "" Dev ../x dev/x 1dev "dev prod" bootstrap/x "$(printf 'dev\n../x')"; do
  expect_fail "tf/init with ENV '${bad_env//$'\n'/ NEWLINE }'" "ENV must be lowercase" tf_init "$bad_env"
done
expect_fail "tf/init without ENV" "ENV must be lowercase" env -u ENV ACCOUNT="$acct" REGION=ap-southeast-1 "$ROOT/scripts/tf/init.sh"
expect_fail "tf/init without ACCOUNT" "ACCOUNT and REGION must be set" tf_init_as dev "" ap-southeast-1
expect_fail "tf/init without REGION" "ACCOUNT and REGION must be set" tf_init_as dev "$acct" ""
[ ! -e "$sd/calls" ] || die "selftest: tf/init must not run terraform for a refused call"

# --- plan-role-guardrails.sh (stub aws): the plan role must be denied N2 (secret value) and N3 (CreateVpc).
secret_denied="An error occurred (AccessDeniedException) when calling the GetSecretValue operation for ${acct}"
vpc_denied="An error occurred (UnauthorizedOperation) when calling the CreateVpc operation"
guardrails() { stubbed env ENV=dev "$ROOT/scripts/tf/plan-role-guardrails.sh"; }
guardrails_ready() {
  stub_reset
  stub aws-secretsmanager-get-secret-value rc 254
  stub aws-secretsmanager-get-secret-value err "$secret_denied"
  stub aws-ec2-create-vpc rc 254
  stub aws-ec2-create-vpc err "$vpc_denied"
}
guardrails_ready
out="$(guardrails 2>&1)" || die "selftest: the guardrails of a correctly denied plan role failed: $out"
calls_have "--secret-id sis/dev/app-api-key" || die "selftest: the guardrails did not derive the dev secret"
calls_have "ec2 create-vpc --cidr-block 10.255.0.0/16 --dry-run" || die "selftest: the guardrails must only dry-run CreateVpc"
ok "plan role guardrails pass when both calls are denied"
guardrails_ready
stub aws-secretsmanager-get-secret-value rc 0
expect_fail "guardrails when the plan role reads the secret" "N2 (plan role, GetSecretValue) failed: the call succeeded" guardrails
guardrails_ready
stub aws-secretsmanager-get-secret-value err "An error occurred (ThrottlingException) for ${acct}"
expect_fail "guardrails with another N2 error" "for a reason other than AccessDeniedException (exit code 254): An error occurred (ThrottlingException) for <redacted>" guardrails
guardrails_ready
stub aws-ec2-create-vpc err "An error occurred (DryRunOperation) when calling the CreateVpc operation"
expect_fail "guardrails when the plan role could create a VPC" "N3 (plan role, CreateVpc dry run) failed for a reason other than UnauthorizedOperation" guardrails
guardrails_ready
stub aws-ec2-create-vpc rc 0
expect_fail "guardrails when the VPC call succeeds" "N3 (plan role, CreateVpc dry run) failed: the call succeeded" guardrails

# --- tf/resolved-sources.sh: what init resolved must be local modules and hashicorp providers
resolved() { "$ROOT/scripts/tf/resolved-sources.sh" "$tmp/tf" "$tmp/tf/data"; }
mkdir -p "$tmp/tf/data/modules"
printf 'provider "registry.terraform.io/hashicorp/aws" {\n  version = "6.70.0"\n}\n' >"$tmp/tf/.terraform.lock.hcl"
printf '{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"m","Source":"../../modules/m","Dir":"../../modules/m"}]}' >"$tmp/tf/data/modules/modules.json"
resolved >/dev/null 2>&1 || die "selftest: local modules and a hashicorp provider must pass"
rm "$tmp/tf/data/modules/modules.json"
resolved >/dev/null 2>&1 || die "selftest: a directory without modules must pass"
printf '{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"m","Source":"registry.terraform.io/example/m/aws","Dir":".terraform/modules/m"}]}' >"$tmp/tf/data/modules/modules.json"
expect_fail "resolved remote module" "module source is not local: registry.terraform.io/example/m/aws" resolved
printf '{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"m","Source":"git::https://example.com/m.git","Dir":".terraform/modules/m"}]}' >"$tmp/tf/data/modules/modules.json"
expect_fail "resolved git module" "module source is not local" resolved
rm "$tmp/tf/data/modules/modules.json"
printf 'provider "registry.terraform.io/example/aws" {\n  version = "1.0.0"\n}\n' >"$tmp/tf/.terraform.lock.hcl"
expect_fail "resolved non-hashicorp provider" "provider is not hashicorp: registry.terraform.io/example/aws" resolved
rm "$tmp/tf/.terraform.lock.hcl"
expect_fail "resolved sources without a lock file" "no .terraform.lock.hcl" resolved
ok "resolved sources: local modules and hashicorp providers only"

# --- tf/destroy-report.sh: the heading states the real outcome (ADR 0007 S12)
# report <deletes> <apply outcome> [deregistered]: without the third argument DEREGISTERED stays unset.
report() {
  local dereg=()
  if [ $# -ge 3 ]; then dereg=("DEREGISTERED=$3"); fi
  env -u DEREGISTERED ENV=dev DELETES="$1" APPLY_OUTCOME="$2" ROLE=sis-dev-gha-apply ${dereg[@]+"${dereg[@]}"} "$ROOT/scripts/tf/destroy-report.sh"
}
# The whole report is captured first: piping into `head` closes the pipe early and the report dies of SIGPIPE.
report_head() {
  local out
  out="$(report "$@")"
  printf '%s\n' "${out%%$'\n'*}"
}
[ "$(report_head 5 success 4)" = "### Destroyed (dev)" ] || die "selftest: a successful destroy must be headed Destroyed"
[ "$(report_head 5 failure 0)" = "### Destroy failed (dev)" ] || die "selftest: a failed apply must be headed Destroy failed"
[ "$(report_head 5 skipped 0)" = "### Destroy failed (dev)" ] || die "selftest: an apply that did not succeed must not read as Destroyed"
[ "$(report_head 0 skipped 0)" = "### Nothing to destroy (dev)" ] || die "selftest: an empty plan must be headed Nothing to destroy"
[ "$(report_head "" skipped 0)" = "### Destroy did not finish (dev)" ] || die "selftest: a missing plan check must be headed Destroy did not finish"
# shellcheck disable=SC2016  # the backticks are Markdown, not a command
case "$(report 5 success 4)" in
  *"Resources: 5 deleted"*"deregistered: 4"*'Role: `sis-dev-gha-apply`'*) ;;
  *) die "selftest: unexpected destroy report body" ;;
esac
case "$(report 5 failure)" in
  *"deregistered: not known (the cleanup did not start)"*) ;;
  *) die "selftest: an unset DEREGISTERED must read as not known" ;;
esac
case "$(report 5 failure 0)" in
  *"5 planned; the apply did not succeed (failure)"*) ;;
  *) die "selftest: a failed apply must say so" ;;
esac
ok "destroy report headings follow the real outcome"
