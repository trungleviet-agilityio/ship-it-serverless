#!/usr/bin/env bash
# Refuse to promote, or to roll dev back to, a commit that was not green in dev (ADR 0008, P10; ADR 0012 L8). No AWS
# and no registry: only git and the GitHub API. The commit must be 40 lowercase hex characters, an ancestor of
# origin/main, and have a successful app-deploy run on branch main. Run it from a checkout whose history holds
# origin/main (fetch-depth: 0); the credential-free `resolve` jobs of app-promote and of app-deploy (mode rollback) do
# that, with `actions: read` for gh.
#
# Prints nothing on stdout. Exit codes: 0 promotable, 1 refused.
#
# Usage: scripts/image/promote-resolve.sh <commit sha>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 1 ] || die "usage: scripts/image/promote-resolve.sh <commit sha>"
sha="$1"
require_cmd git "install git"
require_cmd gh "the GitHub CLI is preinstalled on GitHub runners"
require_cmd jq "install jq"

# [[ =~ ]] matches the whole value, so a newline cannot smuggle a second line past it.
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "the commit must be 40 lowercase hex characters"

git cat-file -e "${sha}^{commit}" 2>/dev/null || die "commit ${sha} is not in this checkout (fetch the full history of main)"
# merge-base --is-ancestor exits 1 for "not an ancestor" and 128 for an error such as a missing origin/main.
rc=0
git merge-base --is-ancestor "$sha" origin/main 2>/dev/null || rc=$?
case "$rc" in
  0) ;;
  1) die "commit ${sha} is not an ancestor of origin/main" ;;
  *) die "could not compare ${sha} with origin/main (is origin/main fetched?)" ;;
esac
ok "${sha} is on main"

# The run list is filtered on the API side; every field is checked again here, so a loose answer never passes. A run
# counts only if it ran on branch main from a push or a manual dispatch (never a pull_request run) and, in that run:
#   - the job "deploy (dev)" concluded success: a run whose jobs were all skipped (a tag named main, a dispatch on an
#     old commit) has the conclusion success too, so the run conclusion alone proves nothing;
#   - its step "Push the image to ECR" concluded success: the run pushed and released its own commit. A rollback run
#     (mode rollback) skips that step: its head commit is main HEAD, but it released an older commit, so it proves
#     nothing about its head;
#   - the job "verify (dev)" concluded success: /version through the HTTP API showed the commit and the digest (ADR 0012
#     L7, the front-door check without credentials). The first run of an environment ends green with the function not
#     created yet and the verify job skipped (ADR 0012 L3): such an image was never released on Lambda.
deploy_job="deploy (dev)"
push_step="Push the image to ECR"
verify_job="verify (dev)"
run_capture gh run list --workflow app-deploy.yml --commit "$sha" --branch main --status success \
  --json databaseId,headSha,headBranch,event,conclusion --limit 20
[ "$RUN_RC" -eq 0 ] || die "gh run list failed (exit code ${RUN_RC}): ${RUN_ERR}"
candidates="$(jq -r --arg sha "$sha" '
  .[] | select(.headSha == $sha and .conclusion == "success" and .headBranch == "main"
    and (.event == "push" or .event == "workflow_dispatch")) | .databaseId' <<<"$RUN_OUT" 2>/dev/null)" \
  || die "gh run list returned an answer that is not a JSON list of runs"
[ -n "$candidates" ] || die "no successful app-deploy run on main (push or manual dispatch) for ${sha}; it was never green in dev"

green=0
for run_id in $candidates; do
  [[ "$run_id" =~ ^[0-9]+$ ]] || die "gh run list returned a run id that is not a number"
  run_capture gh run view "$run_id" --json jobs
  [ "$RUN_RC" -eq 0 ] || die "gh run view failed (exit code ${RUN_RC}): ${RUN_ERR}"
  if jq -e --arg deploy "$deploy_job" --arg push "$push_step" --arg verify "$verify_job" '
    any(.jobs[]?; .name == $deploy and .conclusion == "success"
      and any(.steps[]?; .name == $push and .conclusion == "success"))
    and any(.jobs[]?; .name == $verify and .conclusion == "success")' <<<"$RUN_OUT" >/dev/null 2>&1; then
    green=1
    break
  fi
done
[ "$green" = 1 ] || die "no app-deploy run for ${sha} has '${deploy_job}' (with its step '${push_step}') and '${verify_job}' succeeded (skipped or failed, or a rollback run); it was never deployed to dev"
ok "${sha} has successful '${deploy_job}' and '${verify_job}' jobs that released it in an app-deploy run on main"
