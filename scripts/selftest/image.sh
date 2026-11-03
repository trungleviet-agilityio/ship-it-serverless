#!/usr/bin/env bash
# Self-tests of the CI helper scripts: the image build mirror policy, the image archive export and the ECR push of that
# archive with crane (stub aws and crane from common.sh; no Docker in the deploy job).
# Run by scripts/ci/selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- image/build.sh mirror policy: a registry refusal moves to the next mirror through a named build context (same
# digest); other failures are final. The fixture Dockerfile has the one literal base line (ADR 0007 S21), so the test
# does not depend on the live app/Dockerfile.
mkdir -p "$tmp/app-fixture"
printf 'FROM public.ecr.aws/docker/library/python:3.13-slim@sha256:%s AS base\nFROM base AS test\nFROM base AS runtime\n' "$digest" >"$tmp/app-fixture/Dockerfile"
build() { stubbed env APP_DIR="$tmp/app-fixture" BUILD_RETRY_DELAYS="0" PYTHON_IMAGE_MIRRORS="dockerfile mirror-b" "$ROOT/scripts/image/build.sh" "$commit" sis-app:test; }
data_limit="429 Too Many Requests - Server message: toomanyrequests: Data limit exceeded"
stub_reset
stub docker-buildx rc 1 0
stub docker-buildx err "$data_limit" 0
build >/dev/null 2>&1 || die "selftest: build should succeed from the second mirror"
[ "$(cat "$sd/docker-buildx.n")" = 2 ] || die "selftest: build should have run twice"
[ "$(grep -c -- '--build-context' "$sd/calls")" = 1 ] || die "selftest: only the mirror attempt may pass a build context"
grep -q -- "--build-context base=docker-image://mirror-b:3.13-slim@sha256:${digest} " "$sd/calls" \
  || die "selftest: the mirror attempt must replace base with the Dockerfile tag and digest"
! head -n1 "$sd/calls" | grep -q -- '--build-context' || die "selftest: the first attempt must build the Dockerfile as written"
ok "build falls back to the next mirror through a named build context on a registry refusal"
# The default round is the Dockerfile as written, then Docker Hub.
stub_reset
stub docker-buildx rc 1 0
stub docker-buildx err "$data_limit" 0
stubbed env APP_DIR="$tmp/app-fixture" BUILD_RETRY_DELAYS="0" "$ROOT/scripts/image/build.sh" "$commit" sis-app:test >/dev/null 2>&1 \
  || die "selftest: the default mirrors should succeed on the second attempt"
grep -q -- "base=docker-image://docker.io/library/python:3.13-slim@sha256:${digest} " "$sd/calls" \
  || die "selftest: the default fallback must be Docker Hub with the Dockerfile digest"
# A bad base line never reaches docker: none, an ARG in FROM, two of them, or a digest without a tag.
# shellcheck disable=SC2016  # the fixtures hold a literal ${PYTHON_IMAGE}
for bad in 'FROM python:3.13-slim AS base' 'FROM ${PYTHON_IMAGE}:3.13-slim@sha256:%s AS base' 'FROM x:1@sha256:%s AS base\nFROM y:2@sha256:%s AS base'; do
  # shellcheck disable=SC2059  # the fixtures are printf formats
  printf "${bad}\n" "$digest" "$digest" >"$tmp/app-fixture/Dockerfile"
  stub_reset
  expect_fail "build with a bad base line" "exactly one 'FROM" build
  [ ! -e "$sd/calls" ] || die "selftest: a bad Dockerfile must not reach docker"
done
printf 'FROM python@sha256:%s AS base\n' "$digest" >"$tmp/app-fixture/Dockerfile"
expect_fail "build with a base image without a tag" "exactly one 'FROM" build
printf 'FROM public.ecr.aws/docker/library/python:3.13-slim@sha256:%s AS base\nFROM base AS test\nFROM base AS runtime\n' "$digest" >"$tmp/app-fixture/Dockerfile"
stub_reset
stub docker-buildx rc 1
stub docker-buildx err "FAIL: test_health_ok (test_app.BoardTest)"
expect_fail "build with a failing test" "not a registry refusal" build
[ "$(cat "$sd/docker-buildx.n")" = 1 ] || die "selftest: a failing test must not be retried"
stub_reset
stub docker-buildx rc 1
stub docker-buildx err "$data_limit"
expect_fail "build when every registry keeps refusing" "kept refusing after 4 attempts" build

# --- image/export.sh
stub_reset
export_out="$(stubbed "$ROOT/scripts/image/export.sh" "$commit" "$tmp/export" 2>/dev/null)" || die "selftest: image/export failed"
[ "$export_out" = "sha256=$(sha256_of "$tmp/export/image.tar")" ] || die "selftest: image/export printed: $export_out"
calls_have "docker save -o $tmp/export/image.tar sis-app:${commit}" || die "selftest: image/export saved the wrong image"
tar_file="$tmp/export/image.tar"
tar_sum="$(sha256_of "$tar_file")"
ok "image export saves the archive and prints its sha256"

# --- ecr-push.sh: crane push of the archive (review L6), digest and media type read back from ECR.
ref_digest="sha256:${digest}"
other_ref="sha256:$(printf 'e%.0s' $(seq 1 64))"
oci="application/vnd.oci.image.manifest.v1+json"
registry="${acct}.dkr.ecr.ap-southeast-1.amazonaws.com"
ecr_line() { printf '%s\t%s\n' "$1" "$2"; }
mkdir -p "$tmp/push-temp"
ecr_push() { stubbed env ACCOUNT="$acct" REGION=ap-southeast-1 "$ROOT/scripts/image/ecr-push.sh" sis-dev-app "$commit" "${1:-$tar_file}" "${2:-$tar_sum}" "$tmp/push-temp"; }
# new_tag: the tag is missing at the first lookup and holds the pushed digest at the second.
new_tag() {
  stub_reset
  stub aws-ecr-describe-images rc 254 0
  stub aws-ecr-describe-images err "An error occurred (ImageNotFoundException) when calling DescribeImages" 0
  stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "$oci")" 1
  stub crane-push out "${registry}/sis-dev-app@${ref_digest}"
}
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "$oci")"
out="$(ecr_push 2>/dev/null)" || die "selftest: ecr-push of an existing tag failed"
[ "$out" = "$(printf 'IMAGE_DIGEST=%s\nIMAGE_REF=%s/sis-dev-app@%s' "$ref_digest" "$registry" "$ref_digest")" ] \
  || die "selftest: unexpected ecr-push output: $out"
! calls_have "crane push" || die "selftest: an existing tag must not be pushed again"
ok "ecr-push reuses an existing tag"
new_tag
out="$(ecr_push 2>"$tmp/push.err")" || die "selftest: ecr-push of a new tag failed: $(cat "$tmp/push.err")"
[ "$out" = "$(printf 'IMAGE_DIGEST=%s\nIMAGE_REF=%s/sis-dev-app@%s' "$ref_digest" "$registry" "$ref_digest")" ] || die "selftest: ecr-push of a new tag printed: $out"
calls_have "crane push ${tar_file} ${registry}/sis-dev-app:${commit}" || die "selftest: the archive must be pushed with crane by tag"
calls_have "crane auth login ${registry} --username AWS --password-stdin" || die "selftest: crane must log in with the password on stdin"
calls_have "aws ecr get-login-password --region ap-southeast-1" || die "selftest: the password must come from ecr get-login-password"
! grep -q "^docker " "$sd/calls" || die "selftest: ecr-push must not call docker"
! grep -qF "$acct" "$tmp/push.err" || die "selftest: ecr-push logged the account ID"
login_dir="$(head -n1 "$sd/docker-config")"
case "$login_dir" in "$tmp/push-temp/crane-config."*) ;; *) die "selftest: the login directory must be under the temp dir, got '$login_dir'" ;; esac
[ ! -e "$login_dir" ] || die "selftest: the temporary registry login was not removed"
ok "ecr-push pushes the archive with crane and a temporary login directory that is removed"
# The archive must be the one the build job reported, before any AWS call.
stub_reset
expect_fail "ecr-push with the wrong sha256" "differs from the build job output" ecr_push "$tar_file" "$digest"
! calls_have "aws " || die "selftest: a tampered archive must be refused before any AWS call"
! calls_have "crane " || die "selftest: a tampered archive must not be pushed"
expect_fail "ecr-push with a malformed sha256" "64 hex" ecr_push "$tar_file" abc
expect_fail "ecr-push with a missing archive" "image tar not found" ecr_push "$tmp/no-such.tar"
expect_fail "ecr-push without a temp dir" "a temp dir is needed" stubbed env ACCOUNT="$acct" REGION=ap-southeast-1 RUNNER_TEMP= "$ROOT/scripts/image/ecr-push.sh" sis-dev-app "$commit" "$tar_file" "$tar_sum"
expect_fail "ecr-push without ACCOUNT" "ACCOUNT and REGION must be set" stubbed env ACCOUNT= REGION=ap-southeast-1 "$ROOT/scripts/image/ecr-push.sh" sis-dev-app "$commit" "$tar_file" "$tar_sum" "$tmp/push-temp"
# A digest crane reports that ECR does not hold, a login failure and a push failure.
new_tag
stub crane-push out "${registry}/sis-dev-app@${other_ref}"
expect_fail "ecr-push whose pushed digest differs from ECR" "but crane pushed ${other_ref}" ecr_push
new_tag
stub crane-push out "pushed"
expect_fail "ecr-push without a digest from crane" "printed no digest" ecr_push
new_tag
stub crane-auth rc 1
stub crane-auth err "login to ${registry} failed"
expect_fail "ecr-push with a failed login" "registry login failed (exit code 1): login to <redacted>" ecr_push
! calls_have "crane push" || die "selftest: a failed login must not push"
login_dir="$(head -n1 "$sd/docker-config")"
[ ! -e "$login_dir" ] || die "selftest: the temporary registry login must be removed on failure too"
new_tag
stub aws-ecr-describe-images rc 254 1
stub aws-ecr-describe-images err "An error occurred (ImageNotFoundException) when calling DescribeImages" 1
stub crane-push rc 1
stub crane-push err "PUT https://${registry}/v2/sis-dev-app/manifests/x: UNAUTHORIZED"
expect_fail "ecr-push with a failed push" "crane push failed (exit code 1): PUT https://<redacted>" ecr_push
# Immutable tags: a push that loses the race to another run reuses the tag that run pushed.
new_tag
stub crane-push rc 1
stub crane-push err "TAG_INVALID: The image tag already exists and cannot be overwritten because the repository is immutable"
out="$(ecr_push 2>"$tmp/push.err")" || die "selftest: a push that lost the race to the tag must reuse it: $(cat "$tmp/push.err")"
[ "$out" = "$(printf 'IMAGE_DIGEST=%s\nIMAGE_REF=%s/sis-dev-app@%s' "$ref_digest" "$registry" "$ref_digest")" ] || die "selftest: the race reuse printed: $out"
grep -q "another run pushed it first" "$tmp/push.err" || die "selftest: the race reuse must be warned about"
stub_reset
stub aws-ecr-describe-images rc 254
stub aws-ecr-describe-images err "An error occurred (AccessDeniedException) for ${acct}"
expect_fail "ecr-push on another error" "describe-images failed (exit code 254): An error occurred (AccessDeniedException) for <redacted>" ecr_push
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "application/vnd.oci.image.index.v1+json")"
expect_fail "ecr-push of an image index" "not a single image manifest" ecr_push
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "sha256:abc" "$oci")"
expect_fail "ecr-push with a malformed digest" "unexpected format" ecr_push
ok "ecr-push checks the archive, the login, the pushed digest and the manifest type"
