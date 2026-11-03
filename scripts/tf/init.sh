#!/usr/bin/env bash
# Initialize and validate one environment root for CI (ADR 0006, G15): the one place for the backend bucket name
# (ADR 0002, B8) and the init flags, shared by the plan, apply and destroy jobs. ENV is the single key: it selects
# infra/terraform/envs/$ENV, and bootstrap is never initialized in CI (ADR 0004, E4). Reads ENV, ACCOUNT and REGION
# from the environment. The bucket name holds the account ID, so the script never prints it.
#
# Usage: ENV=dev ACCOUNT=... REGION=... scripts/tf/init.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev ACCOUNT=... REGION=... scripts/tf/init.sh"
env_name="${ENV:-}" account="${ACCOUNT:-}" region="${REGION:-}"
valid_env "$env_name" || die "ENV must be lowercase letters and digits (${ENV_NAME_HINT}), got '${env_name}'"
[ -n "$account" ] && [ -n "$region" ] || die "ACCOUNT and REGION must be set"
require_cmd terraform "run scripts/ci/install-tools.sh"

dir="infra/terraform/envs/${env_name}"
bucket="$(state_bucket "$env_name" "$account" "$region")"
terraform -chdir="$dir" init -input=false -lockfile=readonly -backend-config="bucket=${bucket}"
terraform -chdir="$dir" validate -no-color
