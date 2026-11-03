# shellcheck shell=bash disable=SC2034  # the variables are read by the scripts that source this file
# Shared helpers for scripts/**/*.sh. Source it; do not run it.
# Written for the bash 3.2 that ships with macOS: no mapfile, no associative arrays, and an empty
# array must not be expanded under `set -u`.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# Colors only on a terminal, so CI logs stay plain (https://no-color.org).
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _blue=$'\033[34m' _green=$'\033[32m' _yellow=$'\033[33m' _red=$'\033[31m' _reset=$'\033[0m'
else
  _blue='' _green='' _yellow='' _red='' _reset=''
fi

# All output goes to stderr, so a script's stdout stays free for data.
log()  { printf '%s==>%s %s\n' "$_blue" "$_reset" "$*" >&2; }
ok()   { printf '%sok%s  %s\n' "$_green" "$_reset" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$_yellow" "$_reset" "$*" >&2; }
# In GitHub Actions the failure also becomes an annotation (the runner reads workflow commands on stderr too).
die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf '%serror%s %s\n' "$_red" "$_reset" "$*" >&2
  fi
  exit 1
}

trap 'die "${BASH_SOURCE[0]##*/}: command failed at line $LINENO"' ERR

# require_cmd <command> <install hint>
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install: $2"
}

# The one definition of "looks like an AWS account ID" (the repo is public). ACCOUNT_ID_DIGITS is any run of 12 digits;
# ACCOUNT_ID_RE is a standalone run (alphanumeric boundaries, like the no-aws-account-id pre-commit hook), so a digit
# run inside a hash or a longer number is not a hit.
ACCOUNT_ID_DIGITS='[0-9]{12}'
ACCOUNT_ID_RE="(^|[^0-9A-Za-z])${ACCOUNT_ID_DIGITS}([^0-9A-Za-z]|\$)"

# redact_ids: filter that replaces every run of 12 digits with <redacted>, so AWS error text can be logged on a
# public repo.
redact_ids() { sed -E "s/${ACCOUNT_ID_DIGITS}/<redacted>/g"; }

# run_capture <command...>: run it without failing the script and record the result in globals:
#   RUN_RC (exit code), RUN_OUT (stdout), RUN_ERR (stderr with 12-digit runs redacted; safe to print).
run_capture() {
  local err_file
  err_file="$(mktemp)"
  RUN_RC=0
  # errtrace (set -E) copies the ERR trap into the substitution, where it would report the expected failure.
  RUN_OUT="$(
    trap - ERR
    "$@" 2>"$err_file"
  )" || RUN_RC=$?
  RUN_ERR="$(redact_ids <"$err_file")"
  rm -f "$err_file"
}

# assert_denied <label> <expected text> <command...>: the call must fail and its stderr must hold the expected text
# (for example AccessDeniedException). A call that succeeds, or fails for any other reason, dies with the redacted
# error, so a broken guardrail and a broken test both turn the job red.
assert_denied() {
  local label="$1" text="$2"
  shift 2
  run_capture "$@"
  [ "$RUN_RC" -ne 0 ] || die "${label} failed: the call succeeded, it must be denied"
  case "$RUN_ERR" in
    *"$text"*) ok "denied as designed (${label}): ${text}" ;;
    *) die "${label} failed for a reason other than ${text} (exit code ${RUN_RC}): ${RUN_ERR}" ;;
  esac
}

# mask <value>: ask the runner to hide a value in every later log line. It prints nothing outside GitHub Actions, so a
# local run or a self-test never carries the value in its output.
mask() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::add-mask::%s\n' "$1" >&2; fi
}

# oidc_token [audience]: (default sts.amazonaws.com) print the job's GitHub OIDC token (needs id-token: write) and mask it. Logs nothing else.
oidc_token() {
  local audience="${1:-sts.amazonaws.com}" response token
  require_cmd jq "install jq"
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
    || die "no OIDC token request variables (the job needs id-token: write)"
  # The audience is a query parameter (GitHub OIDC reference).
  response="$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$audience")" \
    || die "OIDC token request failed (not a role refusal)"
  token="$(jq -r '.value // empty' <<<"$response")"
  [ -n "$token" ] || die "OIDC token response has no value"
  mask "$token"
  printf '%s' "$token"
}

# jwt_claim <token> <claim>: print one claim of a JWT payload (empty when absent). Reads base64url with or without
# padding. Never prints the token.
jwt_claim() {
  local payload
  payload="$(cut -d. -f2 <<<"$1" | tr '_-' '/+')"
  while [ $((${#payload} % 4)) -ne 0 ]; do payload="${payload}="; done
  base64 -d <<<"$payload" | jq -r --arg claim "$2" '.[$claim] // empty'
}

# web_identity_call <role: plan|apply|deploy> <token> [aws args...]: run an unsigned sts assume-role-with-web-identity for
# role gha_role_name <role> in ACCOUNT and REGION. Callers mask ACCOUNT first (a mask printed inside a captured call never reaches the log). It only builds and runs the command, so
# pass it to assert_denied or run_capture. A success holds credentials: never print its stdout.
web_identity_call() {
  local role="$1" token="$2"
  shift 2
  : "${ACCOUNT:?ACCOUNT is not set}" "${REGION:?REGION is not set}"
  require_env
  case "$role" in plan | apply | deploy) ;; *) die "role must be plan, apply or deploy, got '$role'" ;; esac
  # No credentials are needed or sent: --no-sign-request.
  aws sts assume-role-with-web-identity \
    --role-arn "arn:aws:iam::${ACCOUNT}:role/$(gha_role_name "$role")" \
    --role-session-name "gha-oidc-negative-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${role}" \
    --web-identity-token "$token" --region "$REGION" --no-sign-request "$@"
}

# ci_python: print the interpreter the guard helpers use (a Python with PyYAML): CI_PYTHON, else .venv-ci/bin/python
# from `make venv`, else python3. Dies with the fix when PyYAML is missing.
ci_python() {
  local py="${CI_PYTHON:-}"
  if [ -z "$py" ]; then
    if [ -x "$ROOT/.venv-ci/bin/python" ]; then py="$ROOT/.venv-ci/bin/python"; else py=python3; fi
  fi
  "$py" -I -c 'import yaml' >/dev/null 2>&1 || die "pyyaml missing: run make venv (hash locked)"
  printf '%s' "$py"
}

# run_guard_helper <helper.py> <what it enforces> [argument ...]: run a Python helper from scripts/guard/ with the CI
# interpreter (ci_python). The helper prints one violation per line and exits 1 for violations (shown as a list, then a
# count by `what`); any other non-zero exit is a helper failure.
run_guard_helper() {
  local helper="$1" what="$2" py out rc=0
  shift 2
  py="$(ci_python)"
  out="$("$py" -I "$ROOT/scripts/guard/$helper" "$@")" || rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '%s\n' "$out" | sed 's/^/  - /' >&2
    die "$(grep -c '' <<<"$out") ${what} violation(s)"
  fi
  [ "$rc" -eq 0 ] || die "${helper} failed (exit code $rc)"
}

# run_workflow_helper <helper.py> <what it enforces> [workflow file ...]: run_guard_helper over the workflow files
# (default: every .github/workflows/*.yml and *.yaml).
run_workflow_helper() {
  local helper="$1" what="$2" f
  shift 2
  local files=("$@")
  if [ ${#files[@]} -eq 0 ]; then
    for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
      if [ -f "$f" ]; then files+=("$f"); fi
    done
    [ ${#files[@]} -gt 0 ] || die "no workflow files found under .github/workflows"
  fi
  run_guard_helper "$helper" "$what" "${files[@]}"
}

# sha256_of <file>: hex digest on Linux and macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- App deploy contract: the one place for names and limits the deploy scripts share.

# The project prefix of every name (project.env). PROJECT_PREFIX in the environment wins, so the self-tests can pin
# their fixture prefix; nothing else sets it. The Terraform validations use the same pattern.
PREFIX_RE='^[a-z][a-z0-9]{1,9}$'
PROJECT_PREFIX="${PROJECT_PREFIX:-$(sed -n 's/^PREFIX=//p' "$ROOT/project.env" 2>/dev/null || true)}"
[[ "$PROJECT_PREFIX" =~ $PREFIX_RE ]] \
  || die "project.env must set PREFIX to 2 to 10 lowercase letters or digits, starting with a letter, got '${PROJECT_PREFIX}'"

# image_name <commit sha>: the local image name every build, smoke, scan and push step uses.
image_name() { printf '%s-app:%s' "$PROJECT_PREFIX" "$1"; }

# The one rule for an environment name (ADR 0008, P4): 2 to 8 lowercase letters and digits, starting with a letter. The
# cap keeps every AWS name built from it in its limit. The Terraform validations use the same pattern. RESERVED_ENVS
# are names that would collide with a directory or a word in the repo (new-env.sh refuses them).
ENV_NAME_RE='^[a-z][a-z0-9]{1,7}$'
RESERVED_ENVS="local bootstrap modules tests shared all env"
ENV_NAME_HINT="2 to 8 lowercase letters and digits, starting with a letter"

# valid_env <name>: [[ =~ ]] matches the whole value, so a newline cannot smuggle a second line past it.
valid_env() {
  [[ "$1" =~ $ENV_NAME_RE ]]
}

# require_env: ENV defaults to dev and must be a valid environment name.
require_env() {
  ENV="${ENV:-dev}"
  valid_env "$ENV" || die "ENV must be lowercase letters and digits (${ENV_NAME_HINT}), got '$ENV'"
}

# env_root <env>: print the Terraform root of an environment (relative to the repo root). Dies when the name is invalid or
# the root does not exist, so a typo never reaches a credentialed step.
env_root() {
  valid_env "$1" || die "ENV must be lowercase letters and digits (${ENV_NAME_HINT}), got '$1'"
  [ -d "$ROOT/infra/terraform/envs/$1" ] || die "no environment root infra/terraform/envs/$1"
  printf 'infra/terraform/envs/%s' "$1"
}

# app_names: derive the resource names of one environment from ENV (default dev; ADR 0001, naming; ADR 0012 L3, L4).
# FUNCTION, ALIAS and API are the Lambda function, its serving alias and the HTTP API (Terraform); REPOSITORY is the ECR
# repository (bootstrap); SECRET_ID is the app secret (shell only, Terraform). The log groups are named for messages.
app_names() {
  require_env
  local p="${PROJECT_PREFIX}-${ENV}"
  FUNCTION="${p}-app" ALIAS="live" API="${p}-api" REPOSITORY="${p}-app"
  SECRET_ID="${PROJECT_PREFIX}/${ENV}/app-api-key"
  FUNCTION_LOG_GROUP="/aws/lambda/${p}-app" API_LOG_GROUP="/aws/apigateway/${p}-api"
}

# gha_role_name <plan|apply|deploy>: the name of a GitHub Actions role of ENV (default dev; bootstrap iam_*.tf).
gha_role_name() {
  require_env
  case "$1" in plan | apply | deploy) ;; *) die "role must be plan, apply or deploy, got '$1'" ;; esac
  printf '%s-%s-gha-%s' "$PROJECT_PREFIX" "$ENV" "$1"
}

# state_bucket <env> <account> <region>: the Terraform state bucket of an environment (ADR 0002, B8). It holds the
# account ID, so callers never print it.
state_bucket() { printf '%s-%s-tfstate-%s-%s-an' "$PROJECT_PREFIX" "$1" "$2" "$3"; }

# assumed_role_name: print the name of the role the current AWS credentials assumed, never the session name (it
# carries the run ID). Returns 1 when the caller is not an assumed role. Summaries use it because
# configure-aws-credentials masks the whole ARN in logs.
assumed_role_name() {
  local arn
  run_capture aws sts get-caller-identity --query Arn --output text
  [ "$RUN_RC" -eq 0 ] || return 1
  arn="$RUN_OUT"
  case "$arn" in
    *:assumed-role/*) arn="${arn#*:assumed-role/}"; printf '%s\n' "${arn%%/*}" ;;
    *) return 1 ;;
  esac
}

# --- Lambda deploy contract (ADR 0012 L6 to L8), shared by scripts/lambda/*.sh and their self-tests.

# The description PublishVersion gets: it ties a version to one commit and one image digest, so a rollback can find the
# version again (lambda_version_description <sha> <digest>).
lambda_version_description() { printf 'sha=%s digest=%s' "$1" "$2"; }

# Published versions the deploy keeps (ADR 0012 L8): ECR keeps 20 images, so no kept version points at a deleted one.
DEFAULT_KEEP_VERSIONS=10

# valid_sha <value> / valid_digest <value>: a full commit SHA (40 hex) and an image digest (sha256:<64 hex>).
valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
valid_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }

# The HTTP API endpoint (ADR 0012 L2): https://<10 character API ID>.execute-api.<region>.amazonaws.com, nothing
# before or after. It holds no account ID, so it may travel as a job output to the credential-free verify job.
API_ENDPOINT_RE='^https://[a-z0-9]{10}\.execute-api\.[a-z0-9-]+\.amazonaws\.com$'
valid_api_endpoint() { [[ "$1" =~ $API_ENDPOINT_RE ]]; }

# lambda_http_event <path> <client name>: an API Gateway HTTP API payload v2.0 event for GET <path>, the shape the HTTP
# API sends, so the Lambda Web Adapter forwards it to the app as a GET request. No account ID: accountId is "anonymous".
# smoke-invoke.sh (one version) and canary-bake.sh (the alias) send the same event.
lambda_http_event() {
  jq -cn --arg path "$1" --arg client "$2" --arg id "$2-$RANDOM" --argjson now "$(date +%s)" '{
    version: "2.0", routeKey: "$default", rawPath: $path, rawQueryString: "",
    headers: {accept: "application/json", host: ($client + ".invalid"), "user-agent": $client},
    requestContext: {
      accountId: "anonymous", apiId: "smoke", domainName: ($client + ".invalid"), domainPrefix: $client,
      http: {method: "GET", path: $path, protocol: "HTTP/1.1", sourceIp: "127.0.0.1", userAgent: $client},
      requestId: $id, routeKey: "$default", stage: "$default",
      time: ($now | strftime("%d/%b/%Y:%H:%M:%S +0000")), timeEpoch: ($now * 1000)
    },
    isBase64Encoded: false
  }'
}
