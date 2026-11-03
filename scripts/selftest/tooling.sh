#!/usr/bin/env bash
# Self-tests of the CI helper scripts: the account ID guard, lib.sh helpers, the tool installer, the AWS config check and every script usage contract.
# Run by scripts/ci/selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- aws/assert-no-account-id.sh
[ "$(printf 'commit %s\nok\n' "$commit" | "$ROOT/scripts/aws/assert-no-account-id.sh")" = "$(printf 'commit %s\nok' "$commit")" ] \
  || die "selftest: assert-no-account-id must pass clean text through"
[ "$(printf 'run 0123456789012345678901234567890123456789' | "$ROOT/scripts/aws/assert-no-account-id.sh")" = "run 0123456789012345678901234567890123456789" ] \
  || die "selftest: a long digit string inside a hash must pass"
# shellcheck disable=SC2016  # the inner script is meant to expand in the child shell
expect_fail "summary with a 12-digit run" "12-digit" bash -c 'printf "%s" "$1" | "$2"' _ "role ${leak_id}" "$ROOT/scripts/aws/assert-no-account-id.sh"
# shellcheck disable=SC2016
expect_fail "summary with the exact account" "contains the account ID" bash -c 'printf "%s" "$1" | ACCOUNT=acct-x "$2"' _ "role acct-x" "$ROOT/scripts/aws/assert-no-account-id.sh"
ok "assert-no-account-id passes clean text and refuses account IDs"

# --- lib.sh helpers: die annotation, run_capture, names
# shellcheck disable=SC2016
expect_fail "die inside GitHub Actions" "::error::boom" env GITHUB_ACTIONS=true bash -c 'source "$1/scripts/lib.sh"; die boom' _ "$ROOT"
run_capture bash -c "echo out; echo 'bad ${acct}' >&2; exit 3"
{ [ "$RUN_RC" -eq 3 ] && [ "$RUN_OUT" = "out" ] && [ "$RUN_ERR" = "bad <redacted>" ]; } || die "selftest: run_capture recorded rc=$RUN_RC out=$RUN_OUT err=$RUN_ERR"
names="$(ENV=prod "$ROOT/scripts/names.sh" app)"
[ "$names" = "$(printf 'FUNCTION=sis-prod-app\nALIAS=live\nAPI=sis-prod-api\nREPOSITORY=sis-prod-app\nSECRET_ID=sis/prod/app-api-key')" ] || die "selftest: names app printed: $names"
[ "$("$ROOT/scripts/names.sh" app | head -n1)" = "FUNCTION=sis-dev-app" ] || die "selftest: names app must default to dev"
[ "$("$ROOT/scripts/names.sh" image "$commit")" = "sis-app:${commit}" ] || die "selftest: names image printed the wrong name"
[ "$(ENV=dev "$ROOT/scripts/names.sh" env-root)" = "infra/terraform/envs/dev" ] || die "selftest: names env-root printed the wrong root"
[ "$("$ROOT/scripts/names.sh" env-root)" = "infra/terraform/envs/dev" ] || die "selftest: names env-root must default to dev"
for bad_env in Dev a toolongname ../x "dev prod"; do
  expect_fail "names env-root with ENV '$bad_env'" "ENV must be" env ENV="$bad_env" "$ROOT/scripts/names.sh" env-root
done
expect_fail "names env-root for a root that does not exist" "no environment root" env ENV=zz "$ROOT/scripts/names.sh" env-root
# valid_env: the one name rule (ADR 0008, P4): 2 to 8 lowercase letters and digits, starting with a letter.
for good_env in dev prod qa a1 abcdefgh; do valid_env "$good_env" || die "selftest: valid_env rejected '$good_env'"; done
for bad_env in "" a Dev 1ab abcdefghi a-b "a b" "$(printf 'qa\n../x')"; do ! valid_env "$bad_env" || die "selftest: valid_env accepted '${bad_env//$'\n'/ NEWLINE }'"; done
ok "lib helpers: die, run_capture, names and the environment name rule"

# --- ci/install-tools.sh on scratch copies: nothing here touches the network (CI_TOOLS_BASE_URL is a directory)
mkdir -p "$tmp/mirror" "$tmp/pack"
for t in terraform tflint trivy hadolint crane; do
  printf '#!/bin/sh\necho "fake %s"\n' "$t" >"$tmp/pack/$t"
  chmod +x "$tmp/pack/$t"
done
python3 -I - "$tmp" <<'PY'
import sys, zipfile
t = sys.argv[1]
for n in ("terraform", "tflint"):
    with zipfile.ZipFile(f"{t}/mirror/{n}_9.9.9_linux_amd64.zip", "w") as z:
        z.write(f"{t}/pack/{n}", n)
PY
tar -czf "$tmp/mirror/trivy_9.9.9_Linux-64bit.tar.gz" -C "$tmp/pack" trivy
tar -czf "$tmp/mirror/crane_9.9.9_Linux_x86_64.tar.gz" -C "$tmp/pack" crane
cp "$tmp/pack/hadolint" "$tmp/mirror/hadolint_9.9.9_linux_x86_64"
printf 'terraform = "9.9.9"\ntflint = "9.9.9"\ntrivy = "9.9.9"\nhadolint = "9.9.9"\ncrane = "9.9.9"\n' >"$tmp/mise.toml"
: >"$tmp/sums"
for f in terraform_9.9.9_linux_amd64.zip tflint_9.9.9_linux_amd64.zip trivy_9.9.9_Linux-64bit.tar.gz hadolint_9.9.9_linux_x86_64 crane_9.9.9_Linux_x86_64.tar.gz; do
  printf '%s  %s\n' "$(sha256_of "$tmp/mirror/$f")" "$f" >>"$tmp/sums"
done
install_tools() {
  CI_TOOLS_MISE_TOML="$tmp/mise.toml" CI_TOOLS_SHA256="$tmp/sums" CI_TOOLS_BASE_URL="file://$tmp/mirror" \
    "$ROOT/scripts/ci/install-tools.sh" "$@"
}
install_tools "$tmp/bin-default" >"$tmp/install.log" 2>&1 || die "selftest: default install failed: $(cat "$tmp/install.log")"
{ [ -x "$tmp/bin-default/terraform" ] && [ -x "$tmp/bin-default/tflint" ] && [ ! -e "$tmp/bin-default/trivy" ] && [ ! -e "$tmp/bin-default/hadolint" ]; } \
  || die "selftest: no tool arguments must install only terraform and tflint"
install_tools "$tmp/bin-scan" trivy hadolint >"$tmp/install.log" 2>&1 || die "selftest: trivy and hadolint install failed: $(cat "$tmp/install.log")"
{ [ -x "$tmp/bin-scan/trivy" ] && [ -x "$tmp/bin-scan/hadolint" ] && [ ! -e "$tmp/bin-scan/terraform" ]; } || die "selftest: only the named tools may be installed"
install_tools "$tmp/bin-crane" crane >"$tmp/install.log" 2>&1 || die "selftest: crane install failed: $(cat "$tmp/install.log")"
[ -x "$tmp/bin-crane/crane" ] || die "selftest: crane was not installed"
ok "installer installs the named tools only"
expect_fail "installer with an unknown tool" "unknown tool 'kubectl'" install_tools "$tmp/bin-x" kubectl
sed -E 's/^[0-9a-f]{64}  trivy/0000000000000000000000000000000000000000000000000000000000000000  trivy/' "$tmp/sums" >"$tmp/sums-bad"
expect_fail "installer with a corrupted trivy hash" "checksum mismatch" env CI_TOOLS_MISE_TOML="$tmp/mise.toml" \
  CI_TOOLS_SHA256="$tmp/sums-bad" CI_TOOLS_BASE_URL="file://$tmp/mirror" "$ROOT/scripts/ci/install-tools.sh" "$tmp/bin-x" trivy
sed -E 's/^(trivy = ).*/\1"9.9.10"/' "$tmp/mise.toml" >"$tmp/mise-bump.toml"
expect_fail "installer with a bumped trivy version" "no checksum for trivy_9.9.10_Linux-64bit.tar.gz" env \
  CI_TOOLS_MISE_TOML="$tmp/mise-bump.toml" CI_TOOLS_SHA256="$tmp/sums" CI_TOOLS_BASE_URL="file://$tmp/mirror" \
  "$ROOT/scripts/ci/install-tools.sh" "$tmp/bin-x" trivy
# The checked-in pins exist for every tool at the version mise.toml names.
for t in terraform tflint trivy hadolint crane; do
  v="$(sed -nE "s/^${t}[[:space:]]*=[[:space:]]*\"([0-9][^\"]*)\".*/\1/p" "$ROOT/mise.toml" | head -n1)"
  grep -Eq "^[0-9a-f]{64}  ${t}_${v//./\\.}_" "$ROOT/scripts/ci/tools.sha256" || die "selftest: no checked-in checksum for $t $v"
done
ok "checked-in checksums cover every pinned tool"

# --- project.sh: the prefix copies follow project.env (a fork renames the project with one command)
proj="$tmp/project"
for f in project.env infra/terraform/bootstrap/variables.tf app/compose.yaml infra/terraform/envs/dev/terraform.tfvars \
  infra/terraform/envs/prod/terraform.tfvars .github/workflows/terraform-iac.yml .github/workflows/repo-guard.yml; do
  mkdir -p "$proj/$(dirname "$f")"
  cp "$ROOT/$f" "$proj/$f"
done
"$ROOT/scripts/project.sh" set acme "$proj" 2>/dev/null || die "selftest: project set failed"
grep -qx 'PREFIX=acme' "$proj/project.env" || die "selftest: project set did not write project.env"
# shellcheck disable=SC2016  # a literal workflow expression, not a shell one
grep -qF 'acme-${{ env.ENV }}-tfstate-' "$proj/.github/workflows/terraform-iac.yml" || die "selftest: project set missed the bucket host"
grep -q 'image: acme-app:local' "$proj/app/compose.yaml" || die "selftest: project set missed the compose image"
cmp -s "$ROOT/.github/workflows/repo-guard.yml" "$proj/.github/workflows/repo-guard.yml" || die "selftest: project set changed a file without a copy"
printf 'prefix     = "sis"\n' >>"$proj/infra/terraform/envs/prod/terraform.tfvars"
expect_fail "a stale prefix copy" "1 file(s) disagree with project.env" "$ROOT/scripts/project.sh" check "$proj"
case "$EXPECT_OUT" in *"envs/prod/terraform.tfvars"*) ;; *) die "selftest: the stale copy was not named" ;; esac
printf 'PREFIX=Bad-Name\n' >"$proj/project.env"
expect_fail "a bad prefix" "project.env must set PREFIX" "$ROOT/scripts/project.sh" check "$proj"
expect_fail "set a bad prefix" "the prefix must be" "$ROOT/scripts/project.sh" set "a" "$proj"
ok "project.sh sets every prefix copy and names a stale one"

# --- aws/check-config.sh
role=sis-dev-gha-deploy
good_arn="arn:aws:iam::${acct}:role/${role}"
check_cfg() { env ENV=dev ROLE_ARN="$1" ACCOUNT="$2" REGION="$3" "$ROOT/scripts/aws/check-config.sh" deploy; }
out="$(check_cfg "$good_arn" "$acct" ap-southeast-1 2>/dev/null)" || die "selftest: good AWS config rejected"
case "$out" in *"::add-mask::${acct}"*) ok "config check masks the account" ;; *) die "selftest: the account was not masked" ;; esac
expect_fail "config with the plan role" "is not the ${role} role ARN" check_cfg "arn:aws:iam::${acct}:role/sis-dev-gha-plan" "$acct" ap-southeast-1
expect_fail "config with another account" "differs from the account" check_cfg "$good_arn" "$leak_id" ap-southeast-1
expect_fail "config with no region" "AWS_REGION is empty" check_cfg "$good_arn" "$acct" ""
expect_fail "config with no secrets" "is empty or not set" check_cfg "" "" ap-southeast-1
expect_fail "config with an unknown role kind" "role must be plan, apply or deploy" \
  env ENV=dev ROLE_ARN="$good_arn" ACCOUNT="$acct" REGION=ap-southeast-1 "$ROOT/scripts/aws/check-config.sh" "$role"
[ "$(ENV=prod "$ROOT/scripts/names.sh" gha-role plan)" = "sis-prod-gha-plan" ] || die "selftest: names gha-role printed the wrong name"

# --- aws/redact-account-ids.sh
redacted="$(printf 'role %s failed' "$acct" | "$ROOT/scripts/aws/redact-account-ids.sh")"
[ "$redacted" = "role <redacted> failed" ] || die "selftest: redact filter output was: $redacted"
ok "redact filter replaces 12-digit runs"

# --- Usage contracts. The Docker-based scripts (build, smoke, scan) run in full in app-ci and in `make image smoke
# scan`, which need Docker and the trivy database; their argument contracts are checked here, with the rest.
# A script that takes arguments prints its usage when called with none.
for s in image/build image/smoke lambda/publish lambda/smoke-invoke lambda/shift-alias lambda/canary-bake lambda/verify-live lambda/resolve-image image/verify image/export image/ecr-push image/promote-resolve image/promote-copy aws/check-config \
  aws/assert-web-identity-denied aws/assert-session-cap ci/venv tf/resolved-sources tf/new-env; do
  expect_fail "$s without arguments" "usage:" "$ROOT/scripts/$s.sh"
done
expect_fail "names without arguments" "usage:" "$ROOT/scripts/names.sh"
expect_fail "names image without a commit" "usage:" "$ROOT/scripts/names.sh" image
expect_fail "names with an unknown kind" "usage:" "$ROOT/scripts/names.sh" other
# A script that takes none refuses a stray argument.
for s in lambda/preflight lambda/api-endpoint aws/assert-no-account-id tf/plan-role-guardrails \
  tf/init tf/destroy-check tf/plan-summary tf/destroy-report; do
  expect_fail "$s with a stray argument" "usage:" "$ROOT/scripts/$s.sh" x
done
expect_fail "names app with a stray argument" "usage:" "$ROOT/scripts/names.sh" app x
expect_fail "names role with a stray argument" "usage:" "$ROOT/scripts/names.sh" role x
expect_fail "image/scan with one argument" "usage:" "$ROOT/scripts/image/scan.sh" image-only
expect_fail "lambda/prune-versions with two arguments" "usage:" "$ROOT/scripts/lambda/prune-versions.sh" 10 x

# --- OIDC helpers and the negative tests (ADR 0007 S30 to S32), with stub curl and aws.
# b64url <text> [pad]: base64url without padding, or with it when a second argument is given.
b64url() {
  local out
  out="$(printf '%s' "$1" | base64 | tr -d '\n' | tr '+/' '-_')"
  if [ -z "${2:-}" ]; then out="${out%%=*}"; fi
  printf '%s' "$out"
}
claims='{"sub":"repo:o@1/r@2:pull_request","job_workflow_ref":"o/r/.github/workflows/oidc-smoke-test.yml@refs/pull/7/merge"}'
jwt="$(b64url '{"alg":"none"}').$(b64url "$claims").sig"
claim() { bash -c 'source "$1/scripts/lib.sh"; jwt_claim "$2" "$3"' _ "$ROOT" "$1" "$2"; }
[ "$(claim "$jwt" sub)" = "repo:o@1/r@2:pull_request" ] || die "selftest: jwt_claim could not read an unpadded payload"
# Payloads of every length modulo 4, padded and unpadded.
for v in x xy xyz xyzw; do
  for pad in "" pad; do
    padded_jwt="h.$(b64url "{\"a\":\"$v\"}" "$pad").s"
    [ "$(claim "$padded_jwt" a)" = "$v" ] || die "selftest: jwt_claim failed for value '$v' (padding: '${pad:-none}')"
  done
done
[ -z "$(claim "$jwt" no_such_claim)" ] || die "selftest: an absent claim must read as empty"
ok "jwt_claim decodes padded and unpadded payloads"

cat >"$tmp/stub/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"${STUB_DIR:?}/calls"
[ ! -f "$STUB_DIR/curl.out" ] || cat "$STUB_DIR/curl.out"
[ ! -f "$STUB_DIR/curl.rc" ] || exit "$(cat "$STUB_DIR/curl.rc")"
exit 0
EOF
chmod +x "$tmp/stub/curl"
sts=aws-sts-assume-role-with-web-identity
denied_err="An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation: Not authorized to perform sts:AssumeRoleWithWebIdentity for ${acct}"
# GITHUB_ACTIONS is unset so the leak checks read the same on a laptop and on a runner; one case below sets it to
# prove the account is masked there.
oidc_env() {
  stubbed env -u GITHUB_ACTIONS ACCOUNT="$acct" REGION=ap-southeast-1 GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/req?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token "$@"
}
denied_ready() {
  stub_reset
  stub curl out "{\"value\":\"$jwt\"}"
  stub "$sts" rc 254
  stub "$sts" err "$denied_err"
}
# quiet_run <command...>: stdout and stderr together, the failure code kept out of the way.
quiet_run() { ( trap - ERR; "$@" 2>&1 ) || true; }

denied_ready
out="$(oidc_env "$ROOT/scripts/aws/assert-web-identity-denied.sh" plan apply deploy 2>&1)" || die "selftest: refusals of all three roles should pass: $out"
[ "$(cat "$sd/$sts.n")" = 3 ] || die "selftest: one STS call per role expected"
for r in plan apply deploy; do calls_have "role/sis-dev-gha-$r" || die "selftest: the $r role was not tested"; done
calls_have "--no-sign-request" || die "selftest: the STS calls must be unsigned"
case "$out" in
  *"Token sub: repo:o@1/r@2:pull_request"*"Token job_workflow_ref: o/r/.github/workflows/oidc-smoke-test.yml@refs/pull/7/merge"*) ;;
  *) die "selftest: the token claims were not printed: $out" ;;
esac
case "$out" in *"$acct"* | *"$jwt"*) die "selftest: the output holds the account or the token" ;; esac
ok "web identity denial passes when every role refuses, and prints no secret"

denied_ready
out="$(oidc_env GITHUB_ACTIONS=true "$ROOT/scripts/aws/assert-web-identity-denied.sh" plan 2>&1)" || die "selftest: a refusal on a runner should pass: $out"
case "$out" in *"::add-mask::$acct"*) ;; *) die "selftest: on a runner the account must be masked: $out" ;; esac
case "$(printf '%s\n' "$out" | grep -v '^::add-mask::')" in *"$acct"*) die "selftest: on a runner the account appears outside a mask command" ;; esac
ok "web identity denial masks the account on a runner"

denied_ready
stub "$sts" rc 0 1
stub "$sts" err "" 1
stub "$sts" out '{"Credentials":{"SecretAccessKey":"never-printed"}}' 1
out="$(quiet_run oidc_env "$ROOT/scripts/aws/assert-web-identity-denied.sh" plan apply deploy)"
case "$out" in *"the apply role failed: the call succeeded, it must be denied"*) ;; *) die "selftest: a success must fail as a denial that did not happen: $out" ;; esac
case "$out" in *never-printed*) die "selftest: credentials reached the output" ;; esac
[ "$(cat "$sd/$sts.n")" = 2 ] || die "selftest: the run must stop at the first role that accepts the token"
denied_ready
stub "$sts" err "Could not connect to the endpoint URL ${acct}"
expect_fail "web identity denial on a network error" "for a reason other than AccessDenied" oidc_env "$ROOT/scripts/aws/assert-web-identity-denied.sh" plan
out="$(quiet_run oidc_env "$ROOT/scripts/aws/assert-web-identity-denied.sh" plan)"
case "$out" in *"$acct"*) die "selftest: an error message leaked the account" ;; esac
denied_ready
stub curl rc 22
expect_fail "web identity denial when the token request fails" "OIDC token request failed" oidc_env "$ROOT/scripts/aws/assert-web-identity-denied.sh" plan
denied_ready
stub curl out '{"value":""}'
expect_fail "web identity denial with an empty token" "no value" oidc_env "$ROOT/scripts/aws/assert-web-identity-denied.sh" plan
denied_ready
expect_fail "web identity denial with an unknown role" "role must be plan, apply or deploy" oidc_env "$ROOT/scripts/aws/assert-web-identity-denied.sh" admin
ok "web identity denial fails on success, other errors and token problems"

cap_ready() {
  stub_reset
  stub curl out "{\"value\":\"$jwt\"}"
  stub "$sts" rc 254 0
  stub "$sts" err "An error occurred (ValidationError) when calling the AssumeRoleWithWebIdentity operation: The requested DurationSeconds exceeds the MaxSessionDuration set for this role." 0
  stub "$sts" out "2026-10-27T10:15:00+00:00" 1
}
cap_ready
out="$(oidc_env "$ROOT/scripts/aws/assert-session-cap.sh" plan 2>&1)" || die "selftest: a refused 3601 and a granted 900 should pass: $out"
case "$out" in *"session expires in about 15 minutes (2026-10-27T10:15:00+00:00)"*) ;; *) die "selftest: the expiry line is missing: $out" ;; esac
calls_have "--duration-seconds 3601" || die "selftest: the over-cap duration must be requested"
calls_have "--duration-seconds 900" || die "selftest: the short duration must be requested"
case "$out" in *"$acct"* | *"$jwt"* | *Credentials* | *SecretAccessKey*) die "selftest: the session cap output holds a secret" ;; esac
cap_ready
stub "$sts" rc 0 0
expect_fail "session cap when 3601 seconds is granted" "the call succeeded, it must be denied" oidc_env "$ROOT/scripts/aws/assert-session-cap.sh" plan
cap_ready
stub "$sts" err "An error occurred (AccessDenied) for ${acct}" 0
expect_fail "session cap when 3601 fails for another reason" "for a reason other than DurationSeconds" oidc_env "$ROOT/scripts/aws/assert-session-cap.sh" plan
cap_ready
stub "$sts" rc 254 1
stub "$sts" err "An error occurred (AccessDenied)" 1
expect_fail "session cap when 900 seconds is refused" "a 900 second session was refused" oidc_env "$ROOT/scripts/aws/assert-session-cap.sh" plan
ok "session cap: 3601 refused for the duration, 900 reports its expiry"

# --- Script modes (ADR 0007 S19): libraries are only sourced, so they are not executable; everything else is.
modes="$(git -C "$ROOT" ls-files -s 'scripts/*.sh' 2>/dev/null || true)"
if [ -z "$modes" ]; then
  warn "no git index here, skipping the script mode check"
else
  while read -r mode _ _ path; do
    case "$path" in
      scripts/lib.sh | scripts/selftest/common.sh) want=100644 ;;
      *) want=100755 ;;
    esac
    [ "$mode" = "$want" ] || die "selftest: $path is mode $mode, expected $want (libraries 100644, scripts 100755)"
  done <<<"$modes"
  ok "libraries are not executable and every script is"
fi
