#!/usr/bin/env bash
# Copy one image between ECR repositories by digest and prove the digest survived (ADR 0008, P9 steps 4 and 5, S2).
# Needs the AWS CLI (for the registry login) and crane, with credentials that may pull the source and push the target.
#
# The target tag <sha> is read first, then one decision:
#   - the target tag exists: the target digest is used and nothing is copied (the rollback path: promoting an earlier
#     green commit again deploys the digest prod already holds). The source is only a cross-check, best effort: if it
#     cannot be reached for any reason (login or read denied, tag or repository gone) one line says so and the target
#     digest is reused. If the source is readable and holds another digest the run fails (a tag that points at two
#     images is never deployed).
#   - the target tag is missing: everything is strict. The source must be reachable and have the tag. `crane copy`
#     copies source@digest to target:<sha>, the target digest is read again and must equal the source digest.
#
# crane logs in through a temporary DOCKER_CONFIG directory created under <temp dir> (default $RUNNER_TEMP) and removed
# on exit, success or failure. Registry hosts hold the account ID, so nothing prints them: logs carry the digest and the
# commit only, and failure text goes through the account ID redaction.
#
# Prints on stdout: IMAGE_DIGEST=<sha256:...> and PROMOTE_COPIED=<true|false>.
#
# Usage: scripts/image/promote-copy.sh <source repo> <target repo> <commit sha> [temp dir]
#   a repo is <account>.dkr.ecr.<region>.amazonaws.com/<repository name>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

usage="usage: scripts/image/promote-copy.sh <source repo> <target repo> <commit sha> [temp dir]"
{ [ $# -eq 3 ] || [ $# -eq 4 ]; } || die "$usage"
source_repo="$1" target_repo="$2" sha="$3" temp_base="${4:-${RUNNER_TEMP:-}}"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd crane "scripts/ci/install-tools.sh <dir> crane"

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "the commit must be 40 lowercase hex characters"
repo_re='^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/[a-z0-9][a-z0-9._/-]*$'
[[ "$source_repo" =~ $repo_re ]] || die "the source repo must be <account>.dkr.ecr.<region>.amazonaws.com/<repository>"
source_region="${BASH_REMATCH[1]}"
[[ "$target_repo" =~ $repo_re ]] || die "the target repo must be <account>.dkr.ecr.<region>.amazonaws.com/<repository>"
target_region="${BASH_REMATCH[1]}"
[ "$source_repo" != "$target_repo" ] || die "the source and the target repository must differ"
[ -n "$temp_base" ] && [ -d "$temp_base" ] || die "a temp dir is needed: pass one or set RUNNER_TEMP"

DOCKER_CONFIG="$(mktemp -d "${temp_base%/}/crane-config.XXXXXX")" || die "cannot create a temp directory under the temp dir"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT

# ecr_login <repo> <region>: log crane in to the host of the repo. The password travels through a pipe, never an argument.
ecr_login() {
  aws ecr get-login-password --region "$2" | crane auth login "${1%%/*}" --username AWS --password-stdin
}

# read_digest <repo>: set DIGEST to the digest of <repo>:<sha>, or to "" when the tag (or the repository) is gone, and
# DIGEST_FAILURE to a message when the answer is anything else (a denied pull, a malformed digest). A missing image
# and a broken call must never look alike: callers that need the digest die on DIGEST_FAILURE.
read_digest() {
  run_capture crane digest "${1}:${sha}"
  DIGEST="" DIGEST_FAILURE=""
  if [ "$RUN_RC" -eq 0 ]; then
    if [[ "$RUN_OUT" =~ ^sha256:[0-9a-f]{64}$ ]]; then DIGEST="$RUN_OUT"; else DIGEST_FAILURE="crane returned a digest in an unexpected format"; fi
  else
    case "$RUN_ERR" in
      *MANIFEST_UNKNOWN* | *NAME_UNKNOWN*) ;;
      *) DIGEST_FAILURE="crane digest failed (exit code ${RUN_RC}): ${RUN_ERR}" ;;
    esac
  fi
}
# require_digest <repo>: read_digest that dies on a failed call (a missing tag is still an empty DIGEST).
require_digest() {
  read_digest "$1"
  [ -z "$DIGEST_FAILURE" ] || die "$DIGEST_FAILURE"
}

run_capture ecr_login "$target_repo" "$target_region"
[ "$RUN_RC" -eq 0 ] || die "target registry login failed (exit code ${RUN_RC}): ${RUN_ERR}"
require_digest "$target_repo"
target_digest="$DIGEST"

if [ -n "$target_digest" ]; then
  # The rollback path. The source is a best-effort cross-check: any failure to reach it only costs the check.
  # The reason is fixed text: error text from the registry could carry the host.
  source_digest="" reason="the source login failed"
  run_capture ecr_login "$source_repo" "$source_region"
  if [ "$RUN_RC" -eq 0 ]; then
    read_digest "$source_repo"
    source_digest="$DIGEST"
    reason="the source read failed"
    [ -n "$DIGEST_FAILURE" ] || reason="the source no longer has the tag"
  fi
  if [ -n "$source_digest" ] && [ "$source_digest" != "$target_digest" ]; then
    die "the target tag ${sha} holds ${target_digest} but the source holds ${source_digest}: one tag, two images; stopped"
  fi
  if [ -z "$source_digest" ]; then
    log "the source could not be cross-checked (${reason}); reusing the target digest"
  fi
  log "the target tag ${sha} exists (digest ${target_digest}); nothing is copied"
  printf 'IMAGE_DIGEST=%s\nPROMOTE_COPIED=false\n' "$target_digest"
  exit 0
fi

run_capture ecr_login "$source_repo" "$source_region"
[ "$RUN_RC" -eq 0 ] || die "source registry login failed (exit code ${RUN_RC}): ${RUN_ERR}"
require_digest "$source_repo"
source_digest="$DIGEST"
[ -n "$source_digest" ] || die "the source has no image tagged ${sha} (it may have aged out of the repository)"
log "copying ${sha} by digest ${source_digest}"
run_capture crane copy "${source_repo}@${source_digest}" "${target_repo}:${sha}"
[ "$RUN_RC" -eq 0 ] || die "crane copy failed (exit code ${RUN_RC}): ${RUN_ERR}"

require_digest "$target_repo"
[ "$DIGEST" = "$source_digest" ] || die "digest mismatch after the copy: the source is ${source_digest}, the target is ${DIGEST:-missing}"
ok "target digest equals source digest: ${source_digest}"
printf 'IMAGE_DIGEST=%s\nPROMOTE_COPIED=true\n' "$source_digest"
