#!/usr/bin/env bash
# Mechanical review of a destroy plan (ADR 0006, G6), because approval comes before the plan exists. Reads
# `terraform show -json <plan>` on stdin and prints the number of deletes. It fails unless every change (no-op and
# read entries are ignored) is exactly ["delete"], so a create, update, replace or forget is refused, and unless
# every deleted address is under module.app_ecs. (the one module call of envs/<env>). It also refuses a plan that
# invokes actions (action_invocations): an action runs code on apply and is not a resource change. A new root
# resource has to update this guard on purpose.
#
# Usage: terraform show -json tfplan | scripts/tf/destroy-check.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: terraform show -json tfplan | scripts/tf/destroy-check.sh"
require_cmd jq "apt-get install jq"

allowed_prefix="module.app_ecs."

plan="$(cat)"

actions="$(jq '(.action_invocations // []) | length' <<<"$plan")"
[ "$actions" -eq 0 ] || die "refusing a destroy plan that invokes ${actions} action(s)"

changes="$(jq -c '[(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])]' <<<"$plan")"

not_delete="$(jq -r '.[] | select(.change.actions != ["delete"]) | "\(.address) (\(.change.actions | join("+")))"' <<<"$changes")"
[ -z "$not_delete" ] || die "refusing a destroy plan with changes other than delete: $(tr '\n' ' ' <<<"$not_delete")"

outside="$(jq -r --arg p "$allowed_prefix" '.[] | select(.address | startswith($p) | not) | .address' <<<"$changes")"
[ -z "$outside" ] || die "refusing to delete outside ${allowed_prefix}: $(tr '\n' ' ' <<<"$outside")"

jq 'length' <<<"$changes"
