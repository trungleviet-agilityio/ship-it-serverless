#!/usr/bin/env bash
# Self-tests of the Lambda deploy helpers (scripts/lambda/*.sh, ADR 0012 L6 to L9) with the stub aws from common.sh and
# a stub curl: preflight, resolve-image, publish (and its rollback reuse), smoke-invoke, shift-alias, canary-bake,
# api-endpoint, verify-live, prune-versions, and names.sh role.
# Run by scripts/ci/selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# A stub curl with the same reply files as the stub aws (key curl): curl.out[.N], curl.rc[.N].
cat >"$tmp/stub/curl" <<'EOF'
#!/usr/bin/env bash
dir="${STUB_DIR:?}" key=curl
n="$(cat "$dir/$key.n" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$dir/$key.n"
echo "curl $*" >>"$dir/calls"
pick() { if [ -f "$dir/$key.$1.$n" ]; then echo "$dir/$key.$1.$n"; elif [ -f "$dir/$key.$1" ]; then echo "$dir/$key.$1"; fi; }
f="$(pick out)"; [ -z "$f" ] || cat "$f"
f="$(pick rc)"; [ -z "$f" ] || exit "$(cat "$f")"
exit 0
EOF
chmod +x "$tmp/stub/curl"

d="sha256:${digest}"
latest="\$LATEST"
other_d="sha256:$(printf 'c%.0s' $(seq 1 64))"
other_sha="$(printf 'd%.0s' $(seq 1 40))"
repo_uri="${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app"
desc="sha=${commit} digest=${d}"
endpoint="https://abc123defg.execute-api.ap-southeast-1.amazonaws.com"
secret_arn="arn:aws:secretsmanager:ap-southeast-1:${acct}:secret:sis/dev/app-api-key-AbCdEf"
# fn_env [APP_ENV] [IMAGE_DIGEST]: the environment Terraform sets on the function.
fn_env() {
  printf '{"APP_ENV":"%s","AWS_LWA_PORT":"8080","AWS_LWA_READINESS_CHECK_PATH":"/health","APP_API_KEY_SECRET_ARN":"%s","IMAGE_DIGEST":"%s"}' \
    "${1:-dev}" "$secret_arn" "${2:-n/a}"
}
# no_acct <text> <label>: the output must not hold the account ID.
no_acct() { case "$1" in *"$acct"*) die "selftest: $2 printed a 12-digit run: $1" ;; esac; }

# === preflight.sh
secret_denied="An error occurred (AccessDeniedException) when calling the GetSecretValue operation for ${acct}"
version_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
stages_current="{\"${version_id}\":[\"AWSCURRENT\"],\"ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee\":[\"AWSPREVIOUS\"]}"
preflight() { stubbed env ENV="${PREFLIGHT_ENV:-dev}" "$ROOT/scripts/lambda/preflight.sh"; }
preflight_ready() {
  stub_reset
  stub aws-lambda-get-function-configuration out "$(printf 'Active\tSuccessful')"
  stub aws-secretsmanager-describe-secret out "$stages_current"
  stub aws-secretsmanager-get-secret-value rc 254
  stub aws-secretsmanager-get-secret-value err "$secret_denied"
}
preflight_ready
out="$(preflight 2>&1)" || die "selftest: the preflight of a ready function failed: $out"
case "$out" in *"$version_id"*) die "selftest: the preflight printed a secret version ID" ;; esac
calls_have "get-function-configuration --function-name sis-dev-app" || die "selftest: the preflight did not derive the dev function"
calls_have "describe-secret --secret-id sis/dev/app-api-key" || die "selftest: the preflight did not describe the dev secret"
PREFLIGHT_ENV=prod preflight >/dev/null 2>&1 || die "selftest: the prod preflight failed"
calls_have "--function-name sis-prod-app" || die "selftest: the preflight did not derive the prod function"
ok "preflight passes for an active function, a current secret and a denied secret value"

# The first run of an environment: no function yet is exit code 3 with the notice, and nothing else is read.
preflight_ready
stub aws-lambda-get-function-configuration rc 254
stub aws-lambda-get-function-configuration err "An error occurred (ResourceNotFoundException) when calling the GetFunctionConfiguration operation: Function not found: arn:aws:lambda:ap-southeast-1:${acct}:function:sis-dev-app"
rc=0
out="$(trap - ERR; preflight 2>&1)" || rc=$?
[ "$rc" -eq 3 ] || die "selftest: a missing function must exit 3, got $rc: $out"
case "$out" in *"function not created yet: run terraform-iac apply for dev after this push"*) ;; *) die "selftest: the missing function notice is wrong: $out" ;; esac
no_acct "$out" "the missing function notice"
! calls_have "secretsmanager" || die "selftest: a missing function must stop before the secret checks"
ok "preflight: a function that does not exist yet exits 3 with the notice"

for answer in "Pending	Successful" "Inactive	Successful" "Failed	Failed" "Active	InProgress" "Active	Failed"; do
  preflight_ready
  stub aws-lambda-get-function-configuration out "$answer"
  expect_fail "preflight with '${answer//	/ }'" "${FUNCTION:-sis-dev-app}" preflight
  ! calls_have "secretsmanager" || die "selftest: a function in '${answer}' must stop before the secret checks"
done
preflight_ready
stub aws-lambda-get-function-configuration out "$(printf 'Inactive\tSuccessful')"
expect_fail "preflight of an inactive function" "is Inactive" preflight
preflight_ready
stub aws-lambda-get-function-configuration out "$(printf 'Active\tInProgress')"
expect_fail "preflight during an update" "in progress" preflight
preflight_ready
stub aws-lambda-get-function-configuration rc 254
stub aws-lambda-get-function-configuration err "An error occurred (AccessDeniedException) for ${acct}"
expect_fail "preflight without lambda read access" "re-apply bootstrap" preflight
no_acct "$EXPECT_OUT" "the access denied preflight"
preflight_ready
stub aws-lambda-get-function-configuration rc 254
stub aws-lambda-get-function-configuration err "An error occurred (ThrottlingException) for ${acct}"
expect_fail "preflight with throttling" "get-function-configuration failed (exit code 254): An error occurred (ThrottlingException) for <redacted>" preflight

# The secret must have an AWSCURRENT version (ADR 0006, G14) and the value must be denied (N4).
for stages in null '{}' '{"v1":["AWSPENDING"]}' '{"v1":["AWSPREVIOUS"],"v2":["AWSPENDING"]}' ''; do
  preflight_ready
  stub aws-secretsmanager-describe-secret out "$stages"
  expect_fail "preflight with secret stages '$stages'" "secret sis/dev/app-api-key has no current value" preflight
done
preflight_ready
stub aws-secretsmanager-describe-secret rc 254
stub aws-secretsmanager-describe-secret err "An error occurred (AccessDeniedException) when calling DescribeSecret for ${acct}"
expect_fail "preflight without DescribeSecret" "re-apply bootstrap (ADR 0006, G14)" preflight
no_acct "$EXPECT_OUT" "the describe-secret failure"
preflight_ready
stub aws-secretsmanager-describe-secret rc 254
stub aws-secretsmanager-describe-secret err "An error occurred (ResourceNotFoundException) when calling DescribeSecret"
expect_fail "preflight with no secret" "the dev stack is not complete" preflight
preflight_ready
stub aws-secretsmanager-get-secret-value rc 0
stub aws-secretsmanager-get-secret-value out "sis/dev/app-api-key"
expect_fail "preflight when the deploy role can read the secret" "N4 (deploy role, GetSecretValue) failed: the call succeeded" preflight
preflight_ready
stub aws-secretsmanager-get-secret-value err "An error occurred (ResourceNotFoundException)"
expect_fail "preflight with another N4 error" "N4 (deploy role, GetSecretValue) failed for a reason other than AccessDeniedException" preflight
ok "preflight refuses a busy, failed or inactive function, a secret without a value and a readable secret"

# === resolve-image.sh (rollback: the digest of an earlier commit, from ECR)
resolve_image() { stubbed env ENV=dev "$ROOT/scripts/lambda/resolve-image.sh" "$@"; }
stub_reset
stub aws-ecr-describe-images out "$(printf '%s\tapplication/vnd.docker.distribution.manifest.v2+json' "$d")"
[ "$(resolve_image "$commit" 2>/dev/null)" = "IMAGE_DIGEST=${d}" ] || die "selftest: resolve-image did not print the digest"
calls_have "describe-images --repository-name sis-dev-app --image-ids imageTag=${commit}" || die "selftest: resolve-image did not read the tag of the commit"
stub_reset
stub aws-ecr-describe-images out "$(printf '%s\tapplication/vnd.oci.image.index.v1+json' "$d")"
expect_fail "resolve-image of an index" "not a single image manifest" resolve_image "$commit"
stub_reset
stub aws-ecr-describe-images rc 254
stub aws-ecr-describe-images err "An error occurred (ImageNotFoundException) when calling the DescribeImages operation"
expect_fail "resolve-image of a commit that was never pushed" "no image tagged ${commit}" resolve_image "$commit"
stub_reset
expect_fail "resolve-image with a short commit" "40 lowercase hex" resolve_image "${commit:0:12}"
! calls_have "aws " || die "selftest: a malformed commit must not reach AWS"
ok "resolve-image prints the digest of a pushed commit and refuses the rest"

# === publish.sh
publish() { stubbed env ENV="${PUBLISH_ENV:-dev}" "$ROOT/scripts/lambda/publish.sh" "$@"; }
# versions_json <version:description>...: the answer of list-versions-by-function.
versions_json() {
  local v out="{\"Versions\":[{\"Version\":\"${latest}\",\"Description\":\"\"}"
  for v in "$@"; do out="${out},{\"Version\":\"${v%%:*}\",\"Description\":\"${v#*:}\"}"; done
  printf '%s]}' "$out"
}
# version_json <description> <digest of the image> <IMAGE_DIGEST>: the answer of get-function --qualifier.
version_json() {
  printf '{"Code":{"RepositoryType":"ECR","ImageUri":"%s@%s","ResolvedImageUri":"%s@%s"},"Configuration":{"Version":"4","Description":"%s","Environment":{"Variables":%s}}}' \
    "$repo_uri" "$2" "$repo_uri" "$2" "$1" "$(fn_env dev "$3")"
}
publish_ready() {
  stub_reset
  stub aws-lambda-list-versions-by-function out "$(versions_json "3:sha=${other_sha} digest=${other_d}")"
  stub aws-lambda-get-function-configuration out "$(fn_env dev "$other_d")"
  stub aws-lambda-update-function-code out InProgress
  stub aws-lambda-update-function-configuration out InProgress
  stub aws-lambda-publish-version out 4
  stub aws-lambda-get-function out "$(version_json "$desc" "$d" "$d")"
}
publish_ready
out="$(publish "$repo_uri" "$d" "$commit" 2>"$tmp/publish.err")" || die "selftest: publish failed: $(cat "$tmp/publish.err")"
[ "$out" = "$(printf 'VERSION=4\nREUSED=false')" ] || die "selftest: publish printed: $out"
no_acct "$out$(cat "$tmp/publish.err")" "publish"
calls_have "update-function-code --function-name sis-dev-app --image-uri ${repo_uri}@${d}" || die "selftest: the code must be updated by digest"
calls_have "publish-version --function-name sis-dev-app --description ${desc}" || die "selftest: the version must carry sha= and digest="
calls_have "wait published-version-active --function-name sis-dev-app --qualifier 4" || die "selftest: publish must wait for the version"
# The merged environment: every Terraform key unchanged, IMAGE_DIGEST replaced.
env_arg="$(grep 'update-function-configuration' "$sd/calls" | sed 's/.*--environment //; s/ --query.*//')"
jq -e --argjson want "$(fn_env dev "$d")" '.Variables == $want' <<<"$env_arg" >/dev/null || die "selftest: the merged environment is wrong: $env_arg"
# Order: code, wait, configuration, wait, publish (ADR 0012 L6: the digest is set before PublishVersion).
order="$(grep -oE 'lambda (update-function-code|update-function-configuration|publish-version|wait function-updated-v2)' "$sd/calls" | tr '\n' ',')"
[ "$order" = "lambda update-function-code,lambda wait function-updated-v2,lambda update-function-configuration,lambda wait function-updated-v2,lambda publish-version," ] \
  || die "selftest: publish ran its calls in the wrong order: $order"
ok "publish: code by digest, IMAGE_DIGEST merged before PublishVersion, version proven"

# Rollback and re-run: a version with the exact description is reused, nothing changes.
publish_ready
stub aws-lambda-list-versions-by-function out "$(versions_json "2:${desc}" "3:sha=${other_sha} digest=${other_d}")"
out="$(publish "$repo_uri" "$d" "$commit" 2>/dev/null)" || die "selftest: the rollback publish failed"
[ "$out" = "$(printf 'VERSION=2\nREUSED=true')" ] || die "selftest: the rollback publish printed: $out"
calls_have "get-function --function-name sis-dev-app --qualifier 2" || die "selftest: a reused version must be proven"
! grep -qE 'update-function-code|update-function-configuration|publish-version' "$sd/calls" || die "selftest: a reuse must change nothing"
# A description that only starts like ours is not a match.
publish_ready
stub aws-lambda-list-versions-by-function out "$(versions_json "2:${desc} extra")"
[ "$(publish "$repo_uri" "$d" "$commit" 2>/dev/null)" = "$(printf 'VERSION=4\nREUSED=false')" ] || die "selftest: an inexact description must not be reused"
# A reused version whose image is another digest is refused.
publish_ready
stub aws-lambda-list-versions-by-function out "$(versions_json "2:${desc}")"
stub aws-lambda-get-function out "$(version_json "$desc" "$other_d" "$d")"
expect_fail "a reused version with another image" "its resolved image is not @${d}" publish "$repo_uri" "$d" "$commit"
no_acct "$EXPECT_OUT" "the refused reuse"
ok "publish: the rollback path reuses the exact version and proves it"

# The environment must be Terraform's: refused before any change.
publish_ready
stub aws-lambda-get-function-configuration out "$(fn_env prod)"
expect_fail "publish to a function whose APP_ENV is another env" "APP_ENV must be dev" publish "$repo_uri" "$d" "$commit"
! calls_have "update-function-code" || die "selftest: a foreign environment must be refused before the code update"
publish_ready
stub aws-lambda-get-function-configuration out null
expect_fail "publish to a function without environment" "has no environment variables" publish "$repo_uri" "$d" "$commit"
publish_ready
stub aws-lambda-get-function-configuration out "$(fn_env dev "$d")"
publish "$repo_uri" "$d" "$commit" >/dev/null 2>&1 || die "selftest: publish with IMAGE_DIGEST already set failed"
! calls_have "update-function-configuration" || die "selftest: an unchanged IMAGE_DIGEST must not update the configuration"
# PublishVersion returns an existing version when nothing changed: its description then differs.
publish_ready
stub aws-lambda-get-function out "$(version_json "sha=${other_sha} digest=${d}" "$d" "$d")"
expect_fail "publish that returned an older version" "PublishVersion returned an existing version" publish "$repo_uri" "$d" "$commit"
publish_ready
stub aws-lambda-get-function out "$(version_json "$desc" "$d" "n/a")"
expect_fail "a version without its IMAGE_DIGEST" "its IMAGE_DIGEST is not ${d}" publish "$repo_uri" "$d" "$commit"
publish_ready
stub aws-lambda-publish-version out "$latest"
expect_fail "publish-version without a number" "not a version number" publish "$repo_uri" "$d" "$commit"
publish_ready
stub aws-lambda-update-function-code rc 254
stub aws-lambda-update-function-code err "An error occurred (AccessDeniedException) for ${acct}"
expect_fail "a denied code update" "update-function-code failed (exit code 254): An error occurred (AccessDeniedException) for <redacted>" publish "$repo_uri" "$d" "$commit"
publish_ready
stub aws-lambda-wait rc 255
stub aws-lambda-wait err "Waiter FunctionUpdatedV2 failed: Waiter encountered a terminal failure state"
expect_fail "a failed update" "did not finish" publish "$repo_uri" "$d" "$commit"
! calls_have "publish-version" || die "selftest: a failed update must not publish"
# Arguments: the repository of this environment, by URI only; a digest; a full commit.
for bad in "${repo_uri}:${commit}" "${repo_uri}@${d}" "${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-prod-app" "public.ecr.aws/x/sis-dev-app"; do
  publish_ready
  expect_fail "publish to the repository '${bad}'" "the repository must be" publish "$bad" "$d" "$commit"
done
publish_ready
expect_fail "publish with a bare digest" "sha256:<64 hex>" publish "$repo_uri" "$digest" "$commit"
expect_fail "publish with a short commit" "40 lowercase hex" publish "$repo_uri" "$d" "${commit:0:7}"
! calls_have "aws " || die "selftest: refused arguments must not reach AWS"
ok "publish refuses foreign environments, unproven versions and bad arguments"

# === smoke-invoke.sh
smoke() { stubbed env ENV=dev SMOKE_RETRY_SLEEP=0 "$ROOT/scripts/lambda/smoke-invoke.sh" "$@"; }
ok_meta='{"StatusCode":200,"ExecutedVersion":"4"}'
version_body() { jq -cn --arg s "$1" --arg d "$2" '{git_sha: $s, image_digest: $d, env: "dev"} | tojson'; }
# smoke_ready [version body json string]: /health 200, then /version.
smoke_ready() {
  stub_reset
  stub aws-lambda-invoke out "$ok_meta"
  stub aws-lambda-invoke payload '{"statusCode":200,"headers":{"content-type":"text/plain"},"body":"ok","isBase64Encoded":false}' 0
  stub aws-lambda-invoke payload "{\"statusCode\":200,\"body\":${1:-$(version_body "$commit" "$d")},\"isBase64Encoded\":false}" 1
}
smoke_ready
smoke 4 "$commit" "$d" >/dev/null 2>&1 || die "selftest: the smoke invoke of a good version failed"
calls_have "invoke --function-name sis-dev-app --qualifier 4 --cli-binary-format raw-in-base64-out" || die "selftest: the smoke must invoke the version, not the alias"
# shellcheck disable=SC2016  # literal JSON text of the event
for want in '"version":"2.0"' '"routeKey":"$default"' '"rawPath":"/health"' '"rawPath":"/version"' '"method":"GET"' '"accountId":"anonymous"'; do
  calls_have "$want" || die "selftest: the smoke event lacks $want"
done
smoke_ready
stub aws-lambda-invoke payload "{\"statusCode\":200,\"body\":\"$(version_body "$commit" "$d" | jq -r . | base64 | tr -d '\n')\",\"isBase64Encoded\":true}" 1
smoke 4 "$commit" "$d" >/dev/null 2>&1 || die "selftest: a base64 body must be decoded"
# A cold start may answer 503 once.
smoke_ready
stub aws-lambda-invoke payload '{"statusCode":503,"body":"starting"}' 0
stub aws-lambda-invoke payload '{"statusCode":200,"body":"ok"}' 1
stub aws-lambda-invoke payload "{\"statusCode\":200,\"body\":$(version_body "$commit" "$d")}" 2
smoke 4 "$commit" "$d" >/dev/null 2>&1 || die "selftest: one 503 on /health must be retried"
ok "smoke-invoke sends HTTP API v2 events to the version and checks /health and /version"
smoke_ready
stub aws-lambda-invoke payload '{"statusCode":500,"body":"x"}' 0
stub aws-lambda-invoke payload '{"statusCode":500,"body":"x"}' 1
stub aws-lambda-invoke payload '{"statusCode":500,"body":"x"}' 2
expect_fail "a version whose /health is 500" "GET /health answered 500 3 time(s)" smoke 4 "$commit" "$d"
smoke_ready
stub aws-lambda-invoke out '{"StatusCode":200,"FunctionError":"Unhandled","ExecutedVersion":"4"}'
stub aws-lambda-invoke payload "{\"errorMessage\":\"boom in ${acct}\",\"errorType\":\"Runtime.ExitError\"}" 0
expect_fail "a version with a FunctionError" "FunctionError Unhandled" smoke 4 "$commit" "$d"
no_acct "$EXPECT_OUT" "the FunctionError message"
smoke_ready
stub aws-lambda-invoke payload '"not an http response"' 0
expect_fail "a version that answers no HTTP response" "statusCode missing" smoke 4 "$commit" "$d"
smoke_ready "$(version_body "$other_sha" "$d")"
expect_fail "a version that shows another commit" "git_sha is '${other_sha}'" smoke 4 "$commit" "$d"
smoke_ready "$(version_body "$commit" "n/a")"
expect_fail "a version that shows no digest" "image_digest is 'n/a'" smoke 4 "$commit" "$d"
smoke_ready '"not json"'
expect_fail "a version whose /version is not JSON" "is not JSON" smoke 4 "$commit" "$d"
smoke_ready
stub aws-lambda-invoke rc 254
stub aws-lambda-invoke err "An error occurred (AccessDeniedException) for ${acct}"
expect_fail "a denied invoke" "failed (exit code 254): An error occurred (AccessDeniedException) for <redacted>" smoke 4 "$commit" "$d"
expect_fail "a smoke of \$LATEST" "published version number" smoke "$latest" "$commit" "$d"
expect_fail "a smoke with a bad digest" "sha256:<64 hex>" smoke 4 "$commit" "$digest"
ok "smoke-invoke fails on errors, wrong answers and bad arguments"

# === shift-alias.sh
shift_alias() { stubbed env ENV=dev "$ROOT/scripts/lambda/shift-alias.sh" "$@"; }
alias_json() { printf '{"Name":"live","FunctionVersion":"%s","RoutingConfig":{"AdditionalVersionWeights":%s}}' "$1" "${2:-{\}}"; }
stub_reset
stub aws-lambda-update-alias out "$(alias_json 4)"
[ "$(shift_alias 4 2>/dev/null)" = "$(printf 'ALIAS_VERSION=4\nALIAS_WEIGHTS={}')" ] || die "selftest: shift-alias all at once printed the wrong state"
calls_have 'update-alias --function-name sis-dev-app --name live --function-version 4 --routing-config {"AdditionalVersionWeights":{}}' \
  || die "selftest: all at once must move the primary and clear the weights"
stub_reset
stub aws-lambda-get-alias out "$(alias_json 3)"
stub aws-lambda-update-alias out "$(alias_json 3 '{"4":0.1}')"
out="$(shift_alias 4 --weight 10 2>/dev/null)" || die "selftest: the canary shift failed"
[ "$out" = "$(printf 'ALIAS_VERSION=3\nALIAS_WEIGHTS={"4":0.1}')" ] || die "selftest: the canary shift printed: $out"
calls_have 'update-alias --function-name sis-dev-app --name live --function-version 3 --routing-config {"AdditionalVersionWeights":{"4":0.1}}' \
  || die "selftest: the canary must keep the primary and weight the new version"
stub_reset
stub aws-lambda-update-alias out "$(alias_json 3)"
[ "$(shift_alias --clear-weights 2>/dev/null)" = "$(printf 'ALIAS_VERSION=3\nALIAS_WEIGHTS={}')" ] || die "selftest: clear-weights printed the wrong state"
calls_have 'update-alias --function-name sis-dev-app --name live --routing-config {"AdditionalVersionWeights":{}}' || die "selftest: clear-weights must remove the weights"
! calls_have "--function-version" || die "selftest: clear-weights must not move the primary"
ok "shift-alias: all at once, canary weight and abort"
stub_reset
stub aws-lambda-get-alias out "$(alias_json 4)"
expect_fail "a canary of the primary version" "already the primary" shift_alias 4 --weight 10
! calls_have "update-alias" || die "selftest: a refused canary must not update the alias"
stub_reset
stub aws-lambda-update-alias out "$(alias_json 3 '{"4":0.1}')"
expect_fail "a clear that leaves a weight" "were not removed" shift_alias --clear-weights
stub_reset
stub aws-lambda-update-alias out "$(alias_json 3)"
expect_fail "an alias that did not move" "did not move" shift_alias 4
for bad in "" "4 --weight" "4 --weight 0" "4 --weight 51" "4 --weight 1.5" "4 --percent 10" "$latest" "live" "4 5"; do
  stub_reset
  # shellcheck disable=SC2086  # the arguments are split on purpose
  expect_fail "shift-alias with '${bad}'" "" shift_alias $bad
  ! calls_have "update-alias" || die "selftest: shift-alias '${bad}' must not update the alias"
done
ok "shift-alias refuses bad arguments and checks the result"

# === canary-bake.sh
bake() { stubbed env ENV=dev CANARY_PROBE_INTERVAL=0 CANARY_METRIC_DELAY=0 "$ROOT/scripts/lambda/canary-bake.sh" "$@"; }
datapoints() { printf '{"Label":"x","Datapoints":[{"Sum":%s,"Unit":"Count"},{"Sum":%s,"Unit":"Count"}]}' "$1" "$2"; }
bake_ready() {
  stub_reset
  stub curl out 200
  stub aws-cloudwatch-get-metric-statistics out "$(datapoints 0 0)" 0
  stub aws-cloudwatch-get-metric-statistics out "$(datapoints 3 4)" 1
}
bake_ready
out="$(bake "$endpoint" 4 1 2>/dev/null)" || die "selftest: a healthy canary failed"
[ "$out" = "$(printf 'CANARY_PROBES=12\nCANARY_FAILED_PROBES=0\nCANARY_ERRORS=0\nCANARY_INVOCATIONS=7')" ] || die "selftest: the bake printed: $out"
[ "$(grep -c '^curl ' "$sd/calls")" = 12 ] || die "selftest: one minute must send 12 probes"
calls_have "--max-time 5 ${endpoint}/health" || die "selftest: the probes must GET /health through the API with a timeout"
calls_have "--metric-name Errors --dimensions Name=FunctionName,Value=sis-dev-app Name=Resource,Value=sis-dev-app:live Name=ExecutedVersion,Value=4" \
  || die "selftest: the error metric must be read for the version through the alias"
calls_have "--metric-name Invocations" || die "selftest: the invocations of the version must be read"
ok "canary-bake: probes through the API, then the Errors metric of the version"
bake_ready
stub curl out 502 5
expect_fail "a canary with one failed probe" "1 of 12 probes were not 2xx" bake "$endpoint" 4 1
case "$EXPECT_OUT" in *"CANARY_FAILED_PROBES=1"*) ;; *) die "selftest: a failed canary must still print its counts: $EXPECT_OUT" ;; esac
bake_ready
stub curl out 000 0
stub curl rc 28 0
expect_fail "a canary with a timed-out probe" "1 of 12 probes were not 2xx" bake "$endpoint" 4 1
bake_ready
stub aws-cloudwatch-get-metric-statistics out "$(datapoints 0 2)" 0
expect_fail "a canary with errors" "reported 2 error(s)" bake "$endpoint" 4 1
bake_ready
stub aws-cloudwatch-get-metric-statistics out '{"Datapoints":[]}' 1
out="$(bake "$endpoint" 4 1 2>&1)" || die "selftest: a canary without invocations must pass on its probes: $out"
case "$out" in *"no invocation of version 4"*) ;; *) die "selftest: zero invocations must be reported: $out" ;; esac
bake_ready
stub aws-cloudwatch-get-metric-statistics rc 254 0
stub aws-cloudwatch-get-metric-statistics err "An error occurred (AccessDenied) for ${acct}" 0
expect_fail "a canary whose metrics cannot be read" "get-metric-statistics (Errors) failed (exit code 254): An error occurred (AccessDenied) for <redacted>" bake "$endpoint" 4 1
for bad in "http://abc.execute-api.ap-southeast-1.amazonaws.com 4 1" "https://example.com 4 1" "${endpoint}/ 4 1" "$endpoint 0 1" "$endpoint 4 0" "$endpoint 4 31" "$endpoint 4"; do
  bake_ready
  # shellcheck disable=SC2086  # the arguments are split on purpose
  expect_fail "canary-bake with '${bad}'" "" bake $bad
  ! calls_have "curl " || die "selftest: canary-bake '${bad}' must not probe"
done
ok "canary-bake fails on a failed probe, a timeout, errors and bad arguments"

# === api-endpoint.sh
api_endpoint() { stubbed env ENV="${API_ENV:-dev}" "$ROOT/scripts/lambda/api-endpoint.sh"; }
apis() { printf '{"Items":[%s]}' "$1"; }
api_item() { printf '{"Name":"%s","ApiEndpoint":"%s","ProtocolType":"HTTP"}' "$1" "$2"; }
stub_reset
stub aws-apigatewayv2-get-apis out "$(apis "$(api_item sis-prod-api https://zzz.execute-api.ap-southeast-1.amazonaws.com),$(api_item sis-dev-api "$endpoint")")"
[ "$(api_endpoint 2>/dev/null)" = "API_ENDPOINT=${endpoint}" ] || die "selftest: api-endpoint did not pick sis-dev-api"
[ "$(API_ENV=prod api_endpoint 2>/dev/null)" = "API_ENDPOINT=https://zzz.execute-api.ap-southeast-1.amazonaws.com" ] || die "selftest: api-endpoint did not derive the prod name"
stub_reset
stub aws-apigatewayv2-get-apis out "$(apis "$(api_item sis-prod-api "$endpoint")")"
expect_fail "api-endpoint without the API" "found 0" api_endpoint
stub_reset
stub aws-apigatewayv2-get-apis out "$(apis "$(api_item sis-dev-api "$endpoint"),$(api_item sis-dev-api "$endpoint")")"
expect_fail "api-endpoint with two APIs of the name" "found 2" api_endpoint
stub_reset
stub aws-apigatewayv2-get-apis out "$(apis "$(api_item sis-dev-api "https://${acct}.example.com")")"
expect_fail "api-endpoint with an unexpected endpoint" "unexpected form" api_endpoint
no_acct "$EXPECT_OUT" "the unexpected endpoint"
ok "api-endpoint finds exactly one API by name"

# === verify-live.sh
verify_live() { stubbed env VERIFY_RETRY_SLEEP=0 "$ROOT/scripts/lambda/verify-live.sh" "$@"; }
live_body() { jq -cn --arg s "$1" --arg d "$2" '{git_sha: $s, image_digest: $d}'; }
stub_reset
stub curl out "$(live_body "$commit" "$d")"
verify_live "$endpoint" "$commit" "$d" >/dev/null 2>&1 || die "selftest: verify-live of a matching answer failed"
calls_have "${endpoint}/version" || die "selftest: verify-live must read /version through the API"
stub_reset
stub curl out "$(live_body "$other_sha" "$other_d")" 0
stub curl rc 22 1
stub curl out "$(live_body "$commit" "$d")" 2
verify_live "$endpoint" "$commit" "$d" >/dev/null 2>&1 || die "selftest: verify-live must retry until the alias change shows"
stub_reset
stub curl out "$(live_body "$other_sha" "$d")"
expect_fail "verify-live of another commit" "after 6 attempts (last: git_sha ${other_sha}" verify_live "$endpoint" "$commit" "$d"
stub_reset
stub curl rc 7
expect_fail "verify-live without an answer" "last: no answer" verify_live "$endpoint" "$commit" "$d"
expect_fail "verify-live with a bad endpoint" "the API endpoint must be" verify_live "http://x" "$commit" "$d"
ok "verify-live retries and compares commit and digest"

# === prune-versions.sh
prune() { stubbed env ENV=dev "$ROOT/scripts/lambda/prune-versions.sh" "$@"; }
# prune_ready <primary> <weights json> <highest version>: versions 1..<highest> and $LATEST.
prune_ready() {
  local list="" i
  for i in $(seq 1 "$3"); do list="${list} ${i}:x"; done
  stub_reset
  stub aws-lambda-get-alias out "$(alias_json "$1" "$2")"
  # shellcheck disable=SC2086  # one argument per version
  stub aws-lambda-list-versions-by-function out "$(versions_json $list)"
}
deleted() { grep 'delete-function' "$sd/calls" | sed -n 's/.* --qualifier \([0-9]*\)$/\1/p' | tr '\n' ' '; }
# Every delete in the stub log names the function and a numbered qualifier, and nothing else.
all_qualified() { ! grep 'delete-function' "$sd/calls" | grep -vqE '^aws lambda delete-function --function-name sis-dev-app --qualifier [1-9][0-9]*$'; }
prune_ready 14 '{}' 14
[ "$(prune 2>/dev/null)" = "PRUNED=4" ] || die "selftest: prune of 14 versions keeping 10 must delete 4"
[ "$(deleted)" = "1 2 3 4 " ] || die "selftest: prune deleted '$(deleted)', expected the oldest four, oldest first"
all_qualified || die "selftest: a delete-function call without a version qualifier"
# A rollback: live points at an old version and weights a new one; both stay.
prune_ready 2 '{"14":0.1}' 14
[ "$(prune 2>/dev/null)" = "PRUNED=3" ] || die "selftest: prune must keep the versions live references"
[ "$(deleted)" = "1 3 4 " ] || die "selftest: prune deleted '$(deleted)', expected 1 3 4"
prune_ready 12 '{}' 12
[ "$(prune 5 2>/dev/null)" = "PRUNED=7" ] || die "selftest: prune with keep 5 must delete 7"
prune_ready 3 '{}' 3
[ "$(prune 2>/dev/null)" = "PRUNED=0" ] || die "selftest: nothing to prune must print PRUNED=0"
! calls_have "delete-function" || die "selftest: nothing to prune, but a delete was made"
ok "prune-versions keeps the newest versions and the alias versions, deletes by qualifier only"
prune_ready 14 '{}' 14
stub aws-lambda-delete-function rc 254 1
stub aws-lambda-delete-function err "An error occurred (AccessDeniedException) for ${acct}" 1
expect_fail "prune when a delete is denied" "delete-function sis-dev-app:2 failed (exit code 254): An error occurred (AccessDeniedException) for <redacted>" prune
case "$EXPECT_OUT" in *"PRUNED=1"*) ;; *) die "selftest: a failed prune must print the count so far: $EXPECT_OUT" ;; esac
prune_ready "$latest" '{}' 14
expect_fail "prune with live on \$LATEST" "other than numbered versions" prune
! calls_have "delete-function" || die "selftest: a refused prune must delete nothing"
for bad in 0 1 51 x "10 10"; do
  prune_ready 14 '{}' 14
  # shellcheck disable=SC2086  # the arguments are split on purpose
  expect_fail "prune with keep '${bad}'" "" prune $bad
  ! calls_have "delete-function" || die "selftest: prune '${bad}' must delete nothing"
done
# The script itself: every delete-function call carries --qualifier, and the one delete helper refuses an empty or
# non-numeric qualifier before it calls AWS.
calls_in_code="$(grep -n 'delete-function' "$ROOT/scripts/lambda/prune-versions.sh" | grep -v '^[0-9]*:#' || true)"
[ -n "$calls_in_code" ] || die "selftest: prune-versions.sh has no delete-function call"
# shellcheck disable=SC2016  # the pattern is script text
! grep -v -- '--qualifier "\$1"' <<<"$calls_in_code" | grep -q 'aws lambda delete-function' || die "selftest: a delete-function call in prune-versions.sh lacks --qualifier"
helper="$(sed -n '/^delete_version() {/,/^}/p' "$ROOT/scripts/lambda/prune-versions.sh")"
[ -n "$helper" ] || die "selftest: prune-versions.sh has no delete_version helper"
for q in "" "$latest" live 0; do
  stub_reset
  # shellcheck disable=SC2016  # the inner script is meant to expand in the child shell
  expect_fail "delete_version '${q}'" "refusing to delete without a numbered version qualifier" \
    stubbed bash -c 'source "$1/scripts/lib.sh"; FUNCTION=sis-dev-app; count=0; eval "$2"; delete_version "$3"' _ "$ROOT" "$helper" "$q"
  ! calls_have "delete-function" || die "selftest: delete_version '${q}' reached AWS"
done
ok "prune-versions never deletes without a version qualifier"

# === names.sh role: the role name only, never the session name (it carries the run ID)
role_name() { stubbed "$ROOT/scripts/names.sh" role; }
stub_reset
stub aws-sts-get-caller-identity out "arn:aws:sts::${acct}:assumed-role/sis-dev-gha-apply/gha-apply-12345-1"
[ "$(role_name 2>/dev/null)" = "sis-dev-gha-apply" ] || die "selftest: names role must print the role name only"
stub_reset
stub aws-sts-get-caller-identity out "arn:aws:iam::${acct}:user/someone"
expect_fail "names role for an IAM user" "not an assumed role" role_name
stub_reset
stub aws-sts-get-caller-identity rc 254
stub aws-sts-get-caller-identity err "An error occurred (ExpiredToken) for ${acct}"
expect_fail "names role without credentials" "not an assumed role" role_name
ok "names role prints the role name and fails closed"
