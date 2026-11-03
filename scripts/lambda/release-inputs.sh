#!/usr/bin/env bash
# Validate the release inputs of app-deploy and app-promote (ADR 0012 L7, L8) before any of them is used, and print
# them normalized. The workflows pass the dispatch inputs through the environment, never through `${{ }}` in a script.
# A push has no inputs, so the strategy then comes from the deployment environment's variables (ADR 0012 L7), which
# the workflows pass through env as well (`${{ vars.X }}` in `env:` only, never in run text). Precedence, per value:
# the dispatch input, else the environment variable, else the default. An empty value counts as not set.
#   MODE              deploy (default), rollback (app-deploy only) or promote (app-promote)
#   STRATEGY          dispatch input: all-at-once or canary
#   RELEASE_STRATEGY  vars.RELEASE_STRATEGY of the environment: all-at-once or canary (empty: all-at-once)
#   CANARY_PERCENT    dispatch input: whole percent from 1 to 50
#   VARS_CANARY_PERCENT  vars.CANARY_PERCENT of the environment (default 10)
#   BAKE_MINUTES      dispatch input: whole minutes from 1 to 30
#   VARS_BAKE_MINUTES vars.BAKE_MINUTES of the environment (default 5)
# The canary values are validated for every release (a bad variable fails an all-at-once deploy too, so it is found).
#   SHA             rollback and promote: the 40 lowercase hex commit to release; must be empty for deploy
#   GITHUB_SHA      deploy: the commit of the run (the runner sets it)
# Every value is matched as a whole ([[ =~ ]]), so a newline cannot smuggle a second line into $GITHUB_ENV.
#
# Prints on stdout: RELEASE_MODE, STRATEGY, CANARY_PERCENT, BAKE_MINUTES and TARGET_SHA as key=value lines, ready to
# append to $GITHUB_ENV. The log line names where the strategy came from (input, environment variable or default).
#
# Usage: MODE=... STRATEGY=... RELEASE_STRATEGY=... CANARY_PERCENT=... VARS_CANARY_PERCENT=... BAKE_MINUTES=...
#        VARS_BAKE_MINUTES=... SHA=... scripts/lambda/release-inputs.sh
# Exit codes: 0 valid, 1 refused.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: MODE=... STRATEGY=... RELEASE_STRATEGY=... CANARY_PERCENT=... VARS_CANARY_PERCENT=... BAKE_MINUTES=... VARS_BAKE_MINUTES=... SHA=... scripts/lambda/release-inputs.sh"
mode="${MODE:-deploy}" sha="${SHA:-}"
# pick <input> <variable value> <default> <input name> <variable name>: the first non-empty of input and variable, else
# the default. The origin is named in the log and in a refusal (a variable is set by the repository admin per
# environment, an input by the dispatcher).
pick() {
  if [ -n "$1" ]; then PICKED="$1" PICKED_FROM="input $4"
  elif [ -n "$2" ]; then PICKED="$2" PICKED_FROM="environment variable $5"
  else PICKED="$3" PICKED_FROM="default"; fi
}
pick "${STRATEGY:-}" "${RELEASE_STRATEGY:-}" all-at-once strategy RELEASE_STRATEGY
strategy="$PICKED" strategy_from="$PICKED_FROM"
pick "${CANARY_PERCENT:-}" "${VARS_CANARY_PERCENT:-}" 10 canary_percent CANARY_PERCENT
pct="$PICKED" pct_from="$PICKED_FROM"
pick "${BAKE_MINUTES:-}" "${VARS_BAKE_MINUTES:-}" 5 bake_minutes BAKE_MINUTES
bake="$PICKED" bake_from="$PICKED_FROM"

[[ "$mode" =~ ^(deploy|rollback|promote)$ ]] || die "mode must be deploy, rollback or promote, got '${mode}'"
[[ "$strategy" =~ ^(all-at-once|canary)$ ]] || die "strategy must be all-at-once or canary, got '${strategy}' (from the ${strategy_from})"
[[ "$pct" =~ ^[1-9][0-9]?$ ]] && [ "$pct" -le 50 ] || die "canary_percent must be a whole percent from 1 to 50, got '${pct}' (from the ${pct_from})"
[[ "$bake" =~ ^[1-9][0-9]?$ ]] && [ "$bake" -le 30 ] || die "bake_minutes must be whole minutes from 1 to 30, got '${bake}' (from the ${bake_from})"
case "$mode" in
  deploy)
    [ -z "$sha" ] || die "sha is for mode rollback only; a deploy releases the commit of the run"
    sha="${GITHUB_SHA:-}"
    valid_sha "$sha" || die "GITHUB_SHA must be 40 lowercase hex characters"
    ;;
  *) valid_sha "$sha" || die "mode ${mode} needs sha: the full 40 lowercase hex commit, got '${sha}'" ;;
esac

detail="$strategy"
if [ "$strategy" = canary ]; then detail="canary, ${pct}% for ${bake} min"; fi
ok "release: ${mode} ${sha} (${detail}; strategy from the ${strategy_from})"
printf 'RELEASE_MODE=%s\nSTRATEGY=%s\nCANARY_PERCENT=%s\nBAKE_MINUTES=%s\nTARGET_SHA=%s\n' "$mode" "$strategy" "$pct" "$bake" "$sha"
