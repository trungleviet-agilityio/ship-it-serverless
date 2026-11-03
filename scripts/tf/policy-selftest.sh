#!/usr/bin/env bash
# Self-test for scripts/tf/policy.sh (ADR 0004, E28): each rule must fail on a bad fixture and pass on a good
# one. Fixtures live in a temporary directory outside the repository.
#
# Usage: scripts/tf/policy-selftest.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

policy="$ROOT/scripts/tf/policy.sh"
n=0

# fixture <name>: create a tree with a clean module and env, print its path.
fixture() {
  local d="$tmp_root/$1"
  mkdir -p "$d/modules/m" "$d/envs/dev"
  cat >"$d/modules/m/main.tf" <<'EOF'
# comments may mention aws_secretsmanager_secret_version, AWSLambdaBasicExecutionRole and provisioner "x" {
resource "aws_iam_role" "ok" {
  name                 = "x"
  permissions_boundary = "arn"
  assume_role_policy   = "{}"
}
EOF
  cat >"$d/envs/dev/backend.tf" <<'EOF'
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    use_lockfile = true
  }
}
EOF
  printf '%s' "$d"
}

# violates <fixture dir> <rule id>: the policy must fail and name policy[<id>].
violates() {
  local out rc=0
  n=$((n + 1))
  # The subshell inherits the ERR trap from lib.sh; clear it so the expected failure stays quiet.
  out="$(trap - ERR; "$policy" "$1" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || die "rule $2: expected failure, got success ($1)"
  case "$out" in
    *"policy[$2]"*) ok "rule $2 fails on its bad fixture" ;;
    *) die "rule $2: failed without naming policy[$2]: $out" ;;
  esac
}

# bad <name> <rule id> <path in the fixture> <content>: write the content (printf %b escapes) over a clean fixture
# and require the rule to fire.
bad() {
  local d
  d="$(fixture "$1")"
  mkdir -p "$(dirname "$d/$3")"
  printf '%b\n' "$4" >"$d/$3"
  violates "$d" "$2"
}

# good <name> <path in the fixture> <content>: the policy must pass.
good() {
  local d
  d="$(fixture "$1")"
  mkdir -p "$(dirname "$d/$2")"
  printf '%b\n' "$3" >"$d/$2"
  "$policy" "$d" >/dev/null 2>&1 || die "fixture $1 must pass"
  ok "fixture $1 passes"
}

d="$(fixture good)"
printf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type        = "Service"\n      identifiers = ["lambda.amazonaws.com"]\n    }\n  }\n}\n' >"$d/modules/m/trust.tf"
printf 'output "name" {\n  # comments may mention module.x.role_arn and account_id\n  value = module.m.name\n}\n' >"$d/envs/dev/outputs.tf"
"$policy" "$d" >/dev/null 2>&1 || die "good fixture must pass"
ok "good fixture passes"

"$policy" "$tmp_root/does-not-exist-parent/none" >/dev/null 2>&1 && die "missing root must fail"
mkdir -p "$tmp_root/empty"
"$policy" "$tmp_root/empty" >/dev/null 2>&1 || die "root without modules/ or envs/ must pass"
ok "absent modules/ and envs/ are no-ops"

# Rule 1 to 4: secrets, security groups, managed policies, permissions boundary.
bad r1 1 envs/dev/s.tf 'resource "aws_secretsmanager_secret_version" "v" {}'
bad r2a 2 modules/m/sg.tf 'resource "aws_security_group_rule" "r" {}'
bad r2b 2 modules/m/sg.tf 'resource "aws_security_group" "s" {\n  ingress {\n  }\n}'
bad r2c 2 modules/m/sg.tf 'resource "aws_security_group" "s" {\n  dynamic "ingress" {\n  }\n}'
bad r2d 2 modules/m/sg.tf 'resource "aws_security_group" "s" {\n  egress = [\n  ]\n}'
bad r3a 3 modules/m/p.tf 'locals { p = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" }'
bad r3c 3 modules/m/p.tf 'locals { p = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole" }'
bad r3b 3 modules/m/p.tf 'resource "aws_iam_role_policy_attachment" "a" {}'
bad r4 4 modules/m/role.tf 'resource "aws_iam_role" "bad" {\n  name = "y"\n}'

# Rule 5: backends.
bad r5a 5 envs/dev/backend.tf 'terraform {\n  backend "s3" {\n    bucket = "b"\n    key = "envs/dev/terraform.tfstate"\n    use_lockfile = true\n  }\n}'
bad r5b 5 envs/dev/backend.tf 'terraform {\n  backend "s3" {\n    key = "envs/dev/terraform.tfstate"\n  }\n}'
bad r5c 5 envs/dev/backend.tf 'terraform {\n  backend "s3" {\n    key = "envs/prod/terraform.tfstate"\n    use_lockfile = true\n  }\n}'
d="$(fixture r5d)"
rm "$d/envs/dev/backend.tf"
printf 'terraform {}\n' >"$d/envs/dev/main.tf"
violates "$d" 5

# Rule 6: providers and backends come from the root.
bad r6a 6 modules/m/prov.tf 'provider "aws" {}'
bad r6b 6 modules/m/be.tf 'terraform {\n  backend "s3" {}\n}'

# Rule 7: module role trust.
bad r7a 7 modules/m/trust.tf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type        = "AWS"\n      identifiers = ["x"]\n    }\n  }\n}'
bad r7b 7 modules/m/trust.tf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type        = "Service"\n      identifiers = ["arn:aws:iam::1:root"]\n    }\n  }\n}'
bad r7c 7 modules/m/trust.tf 'locals {\n  trust = { Principal = { AWS = "x" } }\n}'
bad r7d 7 modules/m/trust.tf 'locals {\n  trust = { Principal = "*" }\n}'
bad r7e 7 modules/m/trust.tf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type = "*"\n      identifiers = ["*"]\n    }\n  }\n}'
bad r7f 7 modules/m/trust.tf 'locals {\n  trust = { Federated = "x" }\n}'
# No exemption is left under modules/ (the promotion pull moved to bootstrap/ecr.tf, ADR 0012 L4): the old line fails
# in a module ecr.tf too.
# shellcheck disable=SC2016  # HCL text
bad r7g 7 modules/m/ecr.tf 'locals {\n  p = { Principal = { AWS = "arn:${local.partition}:iam::${var.promotion_target_account_id}:root" } }\n}'
# shellcheck disable=SC2016  # HCL text
bad r7h 7 modules/m/trust.tf 'locals {\n  p = { Principal = { AWS = "arn:${local.partition}:iam::${var.promotion_target_account_id}:root" } }\n}'

# Rule 8: public root outputs.
bad r8a 8 envs/dev/outputs.tf 'output "a" {\n  value = module.m.role.arn\n}'
bad r8b 8 envs/dev/outputs.tf 'output "a" {\n  value = module.m.ecr_repository_url\n}'
bad r8c 8 envs/dev/outputs.tf 'output "a" {\n  value = module.m.role_arn\n}'
bad r8d 8 envs/dev/outputs.tf 'output "a" {\n  value = data.aws_caller_identity.current.account_id\n}'

# Rule 9: no code execution. Quoted or bare labels, a block opened mid-line.
bad r9a 9 modules/m/prov.tf 'resource "terraform_data" "x" {\n  provisioner "local-exec" {\n    command = "true"\n  }\n}'
bad r9b 9 envs/dev/prov.tf 'resource "terraform_data" "x" {\n  provisioner "local-exec" {\n    command = "true"\n  }\n}'
bad r9c 9 modules/m/ext.tf 'data "external" "x" {\n  program = ["true"]\n}'
bad r9d 9 envs/dev/ext.tf 'data "external" "x" {\n  program = ["true"]\n}'
bad r9e 9 modules/m/prov.tf 'resource "terraform_data" "x" {\n  provisioner local-exec {\n    command = "true"\n  }\n}'
bad r9f 9 envs/dev/ext.tf 'data external x {\n  program = ["true"]\n}'
bad r9g 9 modules/m/prov.tf 'resource "terraform_data" "x" { provisioner "local-exec" { command = "true" } }'
bad r9h 9 envs/dev/ext.tf 'locals { a = 1 } data "external" "x" { program = ["true"] }'

bad r9i 9 modules/m/prov.tf 'resource "terraform_data" "x" {\n  provisioner"local-exec" {\n    command = "true"\n  }\n}'
bad r9j 9 envs/dev/ext.tf 'data"external" "x" {\n  program = ["true"]\n}'

# Rule 10: a JSON twin of a configuration file escapes every line based rule.
bad r10 10 envs/dev/main.tf.json '{"resource": {}}'

# Rule 11: module sources are local paths. A "}" in a string or a comment must not end the block early.
bad r11a 11 envs/dev/mod.tf 'module "x" { source = "git::https://example.com/m.git" }'
bad r11b 11 modules/m/mod.tf 'module "x" {\n  source  = "terraform-aws-modules/vpc/aws"\n  version = "1.0.0"\n}'
bad r11c 11 envs/dev/mod.tf 'module "x" {\n  name = "n"\n  source = "github.com/example/m"\n}'
bad r11d 11 envs/dev/mod.tf 'module "x" {\n  name = "}"\n  source = "github.com/example/m"\n}'
bad r11e 11 envs/dev/mod.tf 'module "x" {\n  name = "n" # }\n  source = "github.com/example/m"\n}'

# Registry-looking sources that a regex without its backslashes would let through ("ab/mod/aws", "a/b").
bad r11f 11 envs/dev/mod.tf 'module "x" {\n  source = "ab/mod/aws"\n}'
bad r11g 11 envs/dev/mod.tf 'module "x" {\n  source = "a/b"\n}'

# Rule 12: provider sources are hashicorp/*, in bootstrap too.
bad r12a 12 envs/dev/versions.tf 'terraform {\n  required_providers {\n    aws = {\n      source = "example/aws"\n    }\n  }\n}'
bad r12b 12 bootstrap/versions.tf 'terraform {\n  required_providers {\n    aws = { source = "registry.example.com/x/aws", version = "1" }\n  }\n}'
bad r12c 12 modules/m/versions.tf 'terraform {\n  required_providers {\n    note = "}"\n    aws = {\n      source = "example/aws"\n    }\n  }\n}'

# These must pass: local sources, hashicorp providers, and a source outside a module or provider block.
good g11 envs/dev/mod.tf 'module "x" { source = "../../modules/app-lambda" }\nmodule "y" {\n  source = "./y"\n}'
good g12 bootstrap/versions.tf 'terraform {\n  required_providers {\n    aws = {\n      source = "hashicorp/aws"\n    }\n  }\n}'
# Bootstrap is outside rule 7: its ECR repository policy names the promotion target account (ADR 0012 L4).
# shellcheck disable=SC2016  # HCL text
good g7promo bootstrap/ecr.tf 'locals {\n  p = {\n    Principal = { AWS = "arn:${local.partition}:iam::${var.promotion_target_account_id}:root" }\n  }\n}'
good gsrc modules/m/other.tf 'resource "x" "y" {\n  source = "anything"\n}'

ok "all $n bad fixtures fail with their rule id"
