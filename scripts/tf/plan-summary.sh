#!/usr/bin/env bash
# Account-free summary of a Terraform plan for the job summary and the PR comment (ADR 0004, E22, E23).
# Reads `terraform show -json <plan>` on stdin and prints markdown: counts and one row per changed resource
# (action and address only, never attribute values). The repo is public, so any bare 12-digit run, which could be
# an AWS account ID, fails the script instead of being printed.
#
# Usage: terraform show -json tfplan | scripts/tf/plan-summary.sh [--title <heading text>]
#        (the default heading is "Terraform plan (<ENV>)", with ENV defaulting to dev)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

require_cmd jq "apt-get install jq"

usage="usage: terraform show -json tfplan | scripts/tf/plan-summary.sh [--title <text>]"
title="Terraform plan (${ENV:-dev})"
case $# in
  0) ;;
  2) { [ "$1" = "--title" ] && [ -n "$2" ]; } || die "$usage"; title="$2" ;;
  *) die "$usage" ;;
esac

max_rows=200

summary="$(
  # shellcheck disable=SC2016  # jq program, not shell
  jq -r --argjson max "$max_rows" --arg title "$title" '
    def act:
      if (.change.actions | index("delete")) and (.change.actions | index("create")) then "REPLACE"
      elif .change.actions == ["delete"] then "DELETE"
      elif .change.actions == ["create"] then "create"
      elif .change.actions == ["update"] then "update"
      else (.change.actions | join("+")) end;
    [(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
    | ($c | map(act)) as $l
    | "### \($title)",
      "",
      "**Add \($l | map(select(. == "create")) | length), change \($l | map(select(. == "update")) | length), destroy \($l | map(select(. == "DELETE")) | length), replace \($l | map(select(. == "REPLACE")) | length).**",
      "",
      (if ($c | length) == 0 then "No resource changes."
       else
         "| Action | Address |",
         "|---|---|",
         ($c[:$max][] | "| \(act) | `\(.address)` |"),
         (if ($c | length) > $max then "", "Showing the first \($max) of \($c | length) changes." else empty end)
       end)
  '
)"

# A standalone 12-digit run may be an account ID (ACCOUNT_ID_RE in lib.sh): refuse to emit it.
if printf '%s\n' "$summary" | grep -Eq "$ACCOUNT_ID_RE"; then
  die "plan summary contains a 12-digit number (possible account ID); not printing it"
fi

printf '%s\n' "$summary"
