#!/usr/bin/env bash
# The end of every deploy (ADR 0012 L6, L7): GET /version through the HTTP API, so through the alias `live`, must show
# <commit sha> and <digest>. An alias change takes effect within seconds, so the read is tried VERIFY_ATTEMPTS times
# (default 6), VERIFY_RETRY_SLEEP seconds apart (default 5), each with a 5 second timeout. Needs curl and jq, and no
# AWS credentials: it runs in the credential-free job `verify (<env>)` after the release job (ADR 0012 L7, review M1),
# which hands it the endpoint, the commit and the digest as job outputs. The endpoint is matched against API_ENDPOINT_RE
# (lib.sh) before any request, so a job output can never point the check at another host.
#
# Usage: scripts/lambda/verify-live.sh <api endpoint> <commit sha> <digest>
#   <api endpoint> is https://<api id>.execute-api.<region>.amazonaws.com (api-endpoint.sh)
# Exit codes: 0 live serves the commit and the digest, 1 it does not.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 3 ] || die "usage: scripts/lambda/verify-live.sh <api endpoint> <commit sha> <digest>"
endpoint="$1" sha="$2" digest="$3"
require_cmd curl "curl is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
valid_api_endpoint "$endpoint" \
  || die "the API endpoint must be https://<10 character api id>.execute-api.<region>.amazonaws.com, got '$(printf '%s' "$endpoint" | redact_ids)'"
valid_sha "$sha" || die "the commit must be 40 lowercase hex characters"
valid_digest "$digest" || die "the digest must be sha256:<64 hex>"
attempts="${VERIFY_ATTEMPTS:-6}" retry_sleep="${VERIFY_RETRY_SLEEP:-5}"

n=1 seen="no answer"
while :; do
  body="$(curl -fsS --max-time 5 "${endpoint}/version" 2>/dev/null)" || body=""
  got="$(printf '%s' "$body" | jq -r '[.git_sha // "missing", .image_digest // "missing"] | @tsv' 2>/dev/null)" || got=""
  if [ -n "$got" ]; then
    seen="git_sha ${got%%$'\t'*}, image_digest ${got#*$'\t'}"
    if [ "$got" = "${sha}"$'\t'"${digest}" ]; then
      ok "live serves commit ${sha} and ${digest} (attempt ${n})"
      exit 0
    fi
  fi
  [ "$n" -lt "$attempts" ] || die "live does not serve commit ${sha} and ${digest} after ${attempts} attempts (last: $(printf '%s' "$seen" | redact_ids))"
  warn "attempt ${n} of ${attempts}: live shows ${seen}; retrying in ${retry_sleep}s"
  n=$((n + 1))
  sleep "$retry_sleep"
done
