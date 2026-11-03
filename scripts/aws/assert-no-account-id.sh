#!/usr/bin/env bash
# Pass stdin to stdout unchanged, unless it holds an AWS account ID: then print nothing and exit 1. The repo is
# public, so a step summary must never carry one. Fails on the exact account in ACCOUNT (optional) and on any
# standalone run of 12 digits.
#
# Usage: <summary command> | [ACCOUNT=...] scripts/aws/assert-no-account-id.sh >> "$GITHUB_STEP_SUMMARY"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: <summary command> | [ACCOUNT=...] scripts/aws/assert-no-account-id.sh"
text="$(cat)"
account="${ACCOUNT:-}"
if [ -n "$account" ] && grep -qF -- "$account" <<<"$text"; then
  die "summary contains the account ID; not publishing"
fi
if grep -Eq "$ACCOUNT_ID_RE" <<<"$text"; then
  die "summary contains a 12-digit number (possible account ID); not publishing"
fi
printf '%s\n' "$text"
