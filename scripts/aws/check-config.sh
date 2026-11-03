#!/usr/bin/env bash
# Check the GitHub configuration of an AWS job before any credential is requested (ADR 0005, F15 step 7).
# Reads ROLE_ARN, ACCOUNT and REGION from the environment, masks the account for the rest of the job, and
# checks that the role ARN names exactly the <role> role of ENV (default dev) in exactly that account. It never prints
# the values.
#
# Usage: ENV=dev ROLE_ARN=... ACCOUNT=... REGION=... scripts/aws/check-config.sh <plan|apply|deploy>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 1 ] || die "usage: ENV=dev scripts/aws/check-config.sh <plan|apply|deploy>"
role_name="$(gha_role_name "$1")"
role_arn="${ROLE_ARN:-}" account="${ACCOUNT:-}" region="${REGION:-}"

[ -n "$role_arn" ] && [ -n "$account" ] || die "The role ARN secret or the account ID secret is empty or not set"
# A workflow command, so it stays on stdout where the runner reads it.
printf '::add-mask::%s\n' "$account"
[ -n "$region" ] || die "Variable AWS_REGION is empty or not set"

printf '%s' "$account" | grep -Eq '^[0-9]{12}$' || die "the account ID secret is not a 12-digit account ID"
printf '%s' "$role_arn" | grep -Eq "^arn:aws:iam::[0-9]{12}:role/${role_name}\$" \
  || die "the role ARN secret is not the ${role_name} role ARN"

role_account="${role_arn#arn:aws:iam::}"
role_account="${role_account%%:*}"
[ "$role_account" = "$account" ] || die "the account ID secret differs from the account in the role ARN"
printf '%s' "$region" | grep -Eq '^[a-z]{2}-[a-z]+-[0-9]$' || die "AWS_REGION is not a region name"
ok "configuration present and well formed"
