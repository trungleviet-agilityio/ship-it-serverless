#!/usr/bin/env bash
# Scan a local image with Trivy (ADR 0005, F8). The image goes through `docker save`, so Trivy never pulls from a
# registry, and it runs with no AWS credentials in the environment (F9). Fixable HIGH and CRITICAL findings and
# secrets fail the scan; exceptions belong in app/.trivyignore with a reason and an exp: date.
#
# Writes <out dir>/trivy.json and <out dir>/counts.txt ("critical=N high=N secrets=N") and appends the counts to
# the step summary (with the vulnerability DB version and update time) when GITHUB_STEP_SUMMARY is set. Needs docker, trivy and jq.
#
# Usage: scripts/image/scan.sh <image> <out dir>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 2 ] || die "usage: scripts/image/scan.sh <image> <out dir>"
image="$1" out="$2"
require_cmd docker "install Docker"
require_cmd trivy "scripts/ci/install-tools.sh <dir> trivy (or mise install)"
require_cmd jq "brew install jq"

mkdir -p "$out"
tar_file="$out/image.tar"
cache="${RUNNER_TEMP:-$out}/trivy-cache"
trap 'rm -f "$tar_file"' EXIT

ignore_args=()
if [ -f "$ROOT/app/.trivyignore" ]; then ignore_args=(--ignorefile "$ROOT/app/.trivyignore"); fi

log "docker save $image"
docker save -o "$tar_file" "$image"

log "trivy image (HIGH and CRITICAL, fixable only)"
rc=0
trivy image --input "$tar_file" --scanners vuln,secret --pkg-types os,library \
  --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
  ${ignore_args[@]+"${ignore_args[@]}"} \
  --format json --output "$out/trivy.json" --no-progress --disable-telemetry \
  --timeout 10m --cache-dir "$cache" >&2 || rc=$?

[ -s "$out/trivy.json" ] || die "trivy wrote no report (exit code $rc)"
trivy convert --format table "$out/trivy.json" >&2 || true

critical="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$out/trivy.json")"
high="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "$out/trivy.json")"
secrets="$(jq '[.Results[]?.Secrets[]?] | length' "$out/trivy.json")"
printf 'critical=%s high=%s secrets=%s\n' "$critical" "$high" "$secrets" >"$out/counts.txt"
# The vulnerability DB version and age, so a stale or odd DB shows in the run (read after the scan downloaded it).
db="$(trivy version --cache-dir "$cache" --format json 2>/dev/null \
  | jq -r '.VulnerabilityDB | "version \(.Version), updated \(.UpdatedAt)"' 2>/dev/null)" || db="unknown"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf 'Trivy: %s critical, %s high, %s secrets (fixable only)\n\n' "$critical" "$high" "$secrets"
    printf 'Trivy vulnerability DB: %s\n' "$db"
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ "$rc" -eq 0 ] || die "trivy found fixable HIGH or CRITICAL issues, or secrets (exit code $rc)"
ok "trivy: $critical critical, $high high, $secrets secrets"
