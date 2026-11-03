#!/usr/bin/env bash
# Build the app image the way CI and the deploy do (ADR 0005, F6; ADR 0007 S21). One platform and no attestations
# keep a single image digest everywhere. The unit tests run inside the build (the runtime stage copies from the test
# stage).
#
# The Dockerfile has one literal `FROM <image>:<tag>@sha256:<digest> AS base` (so Dependabot can bump it), and the
# other stages build FROM base. Any mirror that serves that digest yields the same bits. Anonymous pulls are limited
# per IP (ECR Public also by data volume), and hosted runners share IPs, so on a registry refusal the build moves to
# the next mirror through a named build context: `--build-context base=docker-image://<mirror>:<tag>@sha256:<digest>`
# replaces the stage called base. After a full round it waits and tries again. Any other failure (a test, the
# Dockerfile) is final on the first attempt.
#
# Usage: scripts/image/build.sh <commit sha> [image name:tag]   (default: image_name in lib.sh)
# Env:   PYTHON_IMAGE_MIRRORS  what to try in order. `dockerfile` is the FROM line as written; any other word is a
#                              registry path such as docker.io/library/python (default: `dockerfile`, then Docker Hub)
#        BUILD_RETRY_DELAYS    seconds to wait before each further round (default "30 60"; the self-test sets "0")
#        APP_DIR               build context holding the Dockerfile (default: app/; the self-test uses a fixture)
# Exit codes: 0 built, 1 build or test failure.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

DEFAULT_MIRRORS="dockerfile docker.io/library/python"
# Registry answers that mean "try elsewhere or later": rate and data limits, short outages.
REGISTRY_REFUSALS='429 Too Many Requests|toomanyrequests|503 Service Unavailable|TLS handshake timeout|i/o timeout'

{ [ $# -ge 1 ] && [ $# -le 2 ]; } || die "usage: scripts/image/build.sh <commit sha> [image name:tag]"
sha="$1" image="${2:-$(image_name "$1")}"
app_dir="${APP_DIR:-$ROOT/app}"
require_cmd docker "install Docker"

# The one base line: tag and digest come from it, so a mirror serves exactly the digest the Dockerfile pins.
base_re='^FROM[[:space:]]+[A-Za-z0-9._/-]+:([A-Za-z0-9._-]+)@(sha256:[0-9a-f]{64})[[:space:]]+AS[[:space:]]+base[[:space:]]*$'
base_lines=0 base_tag="" base_digest=""
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ $base_re ]]; then
    base_lines=$((base_lines + 1))
    base_tag="${BASH_REMATCH[1]}" base_digest="${BASH_REMATCH[2]}"
  fi
done <"$app_dir/Dockerfile"
[ "$base_lines" -eq 1 ] || die "app/Dockerfile needs exactly one 'FROM <image>:<tag>@sha256:<64 hex> AS base' line, with a readable tag and no ARG (found $base_lines)"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# build_from <mirror>: one build attempt, output shown and kept in $log. `dockerfile` adds no build context.
build_from() {
  local ctx=()
  if [ "$1" != dockerfile ]; then ctx=(--build-context "base=docker-image://$1:${base_tag}@${base_digest}"); fi
  docker buildx build --platform linux/amd64 --provenance=false --sbom=false --load \
    ${ctx[@]+"${ctx[@]}"} --build-arg GIT_SHA="$sha" -t "$image" "$app_dir" 2>&1 | tee "$log"
}

attempts=0
for delay in ${BUILD_RETRY_DELAYS:-30 60} final; do
  for mirror in ${PYTHON_IMAGE_MIRRORS:-$DEFAULT_MIRRORS}; do
    attempts=$((attempts + 1))
    if build_from "$mirror"; then
      ok "built $image (base from $mirror)"
      exit 0
    fi
    grep -Eq "$REGISTRY_REFUSALS" "$log" || die "build failed (not a registry refusal)"
    warn "registry refusal from $mirror on attempt $attempts"
  done
  [ "$delay" != final ] || die "build failed: every registry kept refusing after $attempts attempts"
  warn "all mirrors refused; next round in ${delay}s"
  sleep "$delay"
done
