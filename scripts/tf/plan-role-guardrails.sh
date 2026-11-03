#!/usr/bin/env bash
# Negative tests of the plan role (N2, N3; ADR 0004): it must be denied what it must not do. Run with the plan role
# credentials in a pull request job. Only reads and dry runs: nothing that writes for real is tried, because a wrong
# pass would damage state. Error text is printed only after 12-digit runs are replaced. Names derive from ENV.
# 1. N2: reading the secret value is an explicit deny (FR-3), so the answer is AccessDeniedException whether or not
#    the secret exists. The call asks for the name only, so even a broken deny could not return the value.
# 2. N3: CreateVpc as a dry run must say UnauthorizedOperation; DryRunOperation would mean the role may create a VPC.
#
# Usage: ENV=dev scripts/tf/plan-role-guardrails.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/tf/plan-role-guardrails.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
app_names

assert_denied "N2 (plan role, GetSecretValue)" AccessDeniedException \
  aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query Name --output text
assert_denied "N3 (plan role, CreateVpc dry run)" UnauthorizedOperation \
  aws ec2 create-vpc --cidr-block 10.255.0.0/16 --dry-run
