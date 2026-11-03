#!/usr/bin/env bash
# Filter: replace every run of 12 digits on stdin with <redacted>, so AWS error text can be logged on a public repo.
#
# Usage: <command> 2>&1 | scripts/aws/redact-account-ids.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

redact_ids
