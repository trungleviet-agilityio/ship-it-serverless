#!/usr/bin/env bash
# Validate the release inputs of app-deploy and app-promote (ADR 0012 L7, L8) before any of them is used, and print
# them normalized. The workflows pass the dispatch inputs through the environment, never through `${{ }}` in a script.
# A push has no inputs, so empty values take the defaults.
#   MODE            deploy (default), rollback (app-deploy only) or promote (app-promote)
#   STRATEGY        all-at-once (default) or canary
#   CANARY_PERCENT  whole percent from 1 to 50 (default 10); only read for canary
#   BAKE_MINUTES    whole minutes from 1 to 30 (default 5); only read for canary
#   SHA             rollback and promote: the 40 lowercase hex commit to release; must be empty for deploy
#   GITHUB_SHA      deploy: the commit of the run (the runner sets it)
# Every value is matched as a whole ([[ =~ ]]), so a newline cannot smuggle a second line into $GITHUB_ENV.
#
# Prints on stdout: RELEASE_MODE, STRATEGY, CANARY_PERCENT, BAKE_MINUTES and TARGET_SHA as key=value lines, ready to
# append to $GITHUB_ENV.
#
# Usage: MODE=... STRATEGY=... CANARY_PERCENT=... BAKE_MINUTES=... SHA=... scripts/lambda/release-inputs.sh
# Exit codes: 0 valid, 1 refused.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: MODE=... STRATEGY=... CANARY_PERCENT=... BAKE_MINUTES=... SHA=... scripts/lambda/release-inputs.sh"
mode="${MODE:-deploy}" strategy="${STRATEGY:-all-at-once}" pct="${CANARY_PERCENT:-10}" bake="${BAKE_MINUTES:-5}" sha="${SHA:-}"

[[ "$mode" =~ ^(deploy|rollback|promote)$ ]] || die "mode must be deploy, rollback or promote, got '${mode}'"
[[ "$strategy" =~ ^(all-at-once|canary)$ ]] || die "strategy must be all-at-once or canary, got '${strategy}'"
[[ "$pct" =~ ^[1-9][0-9]?$ ]] && [ "$pct" -le 50 ] || die "canary_percent must be a whole percent from 1 to 50, got '${pct}'"
[[ "$bake" =~ ^[1-9][0-9]?$ ]] && [ "$bake" -le 30 ] || die "bake_minutes must be whole minutes from 1 to 30, got '${bake}'"
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
ok "release: ${mode} ${sha} (${detail})"
printf 'RELEASE_MODE=%s\nSTRATEGY=%s\nCANARY_PERCENT=%s\nBAKE_MINUTES=%s\nTARGET_SHA=%s\n' "$mode" "$strategy" "$pct" "$bake" "$sha"
