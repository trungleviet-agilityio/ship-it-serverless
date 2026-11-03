#!/usr/bin/env bash
# Save the verified image to <out dir>/image.tar and print its sha256 as `sha256=<hex>` (for $GITHUB_OUTPUT), so
# the deploy job can prove it loads the bytes that were built and scanned.
#
# Usage: scripts/image/export.sh <commit sha> <out dir> >> "$GITHUB_OUTPUT"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 2 ] || die "usage: scripts/image/export.sh <commit sha> <out dir>"
require_cmd docker "install Docker"
mkdir -p "$2"
docker save -o "$2/image.tar" "$(image_name "$1")"
printf 'sha256=%s\n' "$(sha256_of "$2/image.tar")"
