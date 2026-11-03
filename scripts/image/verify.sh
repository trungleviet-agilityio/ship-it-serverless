#!/usr/bin/env bash
# The one recipe that proves an image: build it (the unit tests run inside), smoke test it like Fargate, scan it.
# app-ci, the app-deploy build-scan job and `make verify` all run this; none of them needs AWS.
#
# Usage: scripts/image/verify.sh <commit sha> <scan out dir>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 2 ] || die "usage: scripts/image/verify.sh <commit sha> <scan out dir>"
sha="$1" out="$2"
image="$(image_name "$sha")"

"$ROOT/scripts/image/build.sh" "$sha" "$image"
"$ROOT/scripts/image/smoke.sh" "$image" "$sha"
"$ROOT/scripts/image/scan.sh" "$image" "$out"
