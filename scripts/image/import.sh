#!/usr/bin/env bash
# Load an image tar into Docker only if its sha256 equals the one the build job reported.
#
# Usage: scripts/image/import.sh <image.tar> <expected sha256>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 2 ] || die "usage: scripts/image/import.sh <image.tar> <expected sha256>"
tar_file="$1" expected="$2"
printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' || die "expected sha256 must be 64 hex characters"
[ -f "$tar_file" ] || die "image tar not found: $tar_file"
require_cmd docker "install Docker"

[ "$(sha256_of "$tar_file")" = "$expected" ] || die "image tar sha256 differs from the build job output; refusing to load it"
docker load -i "$tar_file" >&2
ok "loaded the verified image"
