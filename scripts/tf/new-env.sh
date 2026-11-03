#!/usr/bin/env bash
# Clone an environment (ADR 0008, P2): generate infra/terraform/envs/<env>/ from envs/<from>/, the committed
# bootstrap/accounts/<env>.tfvars.example and the gitignored accounts/<env>.tfvars (placeholders only), then print the
# steps you run yourself (account, bootstrap, GitHub environment and secrets, the workflow wiring).
#
# It copies the tracked files of the source root (so the lock file is copied and local state, .terraform/ and
# *.auto.tfvars never are) and rewrites only named keys: `env` in terraform.tfvars and the `key` line of backend.tf.
# Every other line is byte-identical, which the parity guard (scripts/guard/env-parity.sh) enforces afterwards.
# It refuses on any doubt before writing, builds everything in temp paths next to the targets, then moves them in. It
# never runs terraform, aws, gh or a git write, never calls the network, and never takes or prints an account ID.
#
# Usage: scripts/tf/new-env.sh <env> [--from <env>] [--dry-run]
#        make new-env ENV=<env> [FROM=dev] [DRY_RUN=1]
# Exit codes: 0 created (or dry run shown), 1 refused, 2 usage.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

USAGE="usage: scripts/tf/new-env.sh <env> [--from <env>] [--dry-run]"
usage_error() {
  printf '%s\n' "$USAGE" >&2
  exit 2
}

env_name="" from="dev" dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ $# -ge 2 ] || usage_error
      from="$2"
      shift 2
      ;;
    --dry-run) dry_run=1; shift ;;
    -*) usage_error ;;
    *)
      [ -z "$env_name" ] || usage_error
      env_name="$1"
      shift
      ;;
  esac
done
[ -n "$env_name" ] || usage_error

# --- Validation. Nothing is written before every check has passed.
valid_env "$env_name" || die "env must be ${ENV_NAME_HINT}, got '${env_name}'"
valid_env "$from" || die "--from must be ${ENV_NAME_HINT}, got '${from}'"
case " ${RESERVED_ENVS} " in *" ${env_name} "*) die "'${env_name}' is a reserved name (${RESERVED_ENVS})" ;; esac
[ "$env_name" != "$from" ] || die "the new environment must differ from --from ('${from}')"

envs_dir="$ROOT/infra/terraform/envs"
accounts_dir="$ROOT/infra/terraform/bootstrap/accounts"
src="$envs_dir/$from"
src_example="$accounts_dir/${from}.tfvars.example"
dst="$envs_dir/$env_name"
dst_example="$accounts_dir/${env_name}.tfvars.example"
dst_account="$accounts_dir/${env_name}.tfvars"
[ -d "$src" ] || die "source root infra/terraform/envs/${from} does not exist"
[ -f "$src_example" ] || die "infra/terraform/bootstrap/accounts/${from}.tfvars.example does not exist"
[ -f "$src/terraform.tfvars" ] || die "infra/terraform/envs/${from}/terraform.tfvars does not exist"
[ -f "$src/backend.tf" ] || die "infra/terraform/envs/${from}/backend.tf does not exist"

existing=""
for p in "$dst" "$dst_example" "$dst_account"; do
  if [ -e "$p" ]; then existing="${existing}  ${p#"$ROOT"/}"$'\n'; fi
done
[ -z "$existing" ] || die "already exists, nothing was changed:"$'\n'"${existing%$'\n'}"

# Account IDs belong in the secrets, never in the tracked source values.
if grep -Eq '^[[:space:]]*aws_account_id[[:space:]]*=' "$src/terraform.tfvars" || grep -Eq "$ACCOUNT_ID_DIGITS" "$src/terraform.tfvars"; then
  die "envs/${from}/terraform.tfvars holds an aws_account_id or a 12-digit run; remove it first (FR-6)"
fi

# key_count <file> <key>: how many lines assign the key.
key_count() { grep -Ec "^[[:space:]]*$2[[:space:]]*=" "$1" || true; }
# need_once <file> <key>: the rewritten key is assigned exactly once, else the source format changed.
need_once() {
  [ "$(key_count "$1" "$2")" = 1 ] || die "source format changed: '$2' must be assigned exactly once in ${1#"$ROOT"/}; update scripts/tf/new-env.sh"
}
need_once "$src/terraform.tfvars" env
need_once "$src/backend.tf" key
grep -Eq "^[[:space:]]*key[[:space:]]*=[[:space:]]*\"envs/${from}/terraform.tfstate\"" "$src/backend.tf" \
  || die "source format changed: the backend key of envs/${from} is not envs/${from}/terraform.tfstate"

# The gitignored account file must be ignored before it is written.
rel_account="infra/terraform/bootstrap/accounts/${env_name}.tfvars"
git -C "$ROOT" check-ignore -q -- "$rel_account" || die "${rel_account} is not gitignored; refusing to write it (fix .gitignore first)"

env_up="$(printf '%s' "$env_name" | tr '[:lower:]' '[:upper:]')"
from_up="$(printf '%s' "$from" | tr '[:lower:]' '[:upper:]')"
url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
slug="<OWNER>/<REPO>"
if [[ "$url" =~ github\.com[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]]; then slug="${BASH_REMATCH[1]%.git}"; fi

# --- Next steps (printed in a dry run too). Static text with @TOKENS@, so nothing in it is ever expanded by the shell.
print_next_steps() {
  sed -e "s#@PREFIX@#${PROJECT_PREFIX}#g" -e "s#@ENV@#${env_name}#g" -e "s#@ENVUP@#${env_up}#g" -e "s#@SLUG@#${slug}#g" >&2 <<'EOF'

Next steps (you run these; this script never runs terraform, aws or gh):

1. Account. Create or pick the AWS account for @ENV@ and an SSO admin profile named @PREFIX@-@ENV@-admin.
2. Fill infra/terraform/bootstrap/accounts/@ENV@.tfvars (gitignored): account ID, budget email, GitHub owner and repo IDs.
3. Bootstrap the account (first apply on local state, then migrate it to the account's state bucket):
     printf 'terraform {\n  backend "local" {\n    path = "@ENV@.tfstate"\n  }\n}\n' > infra/terraform/bootstrap/backend_override.tf
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap init
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/@ENV@.tfvars -out=@ENV@-bootstrap.tfplan
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap apply @ENV@-bootstrap.tfplan
     rm infra/terraform/bootstrap/backend_override.tf
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap init -migrate-state -backend-config="bucket=@PREFIX@-@ENV@-tfstate-<ENV_ACCOUNT_ID>-ap-southeast-1-an"
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/@ENV@.tfvars
     rm -f infra/terraform/bootstrap/@ENV@.tfstate infra/terraform/bootstrap/@ENV@.tfstate.backup infra/terraform/bootstrap/@ENV@-bootstrap.tfplan
   The second plan must say "No changes".
4. GitHub environment @ENV@ (reviewer, main only) and secrets:
     MY_ID="$(gh api user --jq .id)"
     printf '{"reviewers":[{"type":"User","id":%s}],"prevent_self_review":false,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$MY_ID" | gh api -X PUT repos/@SLUG@/environments/@ENV@ --input -
     gh api -X POST repos/@SLUG@/environments/@ENV@/deployment-branch-policies -f name=main -f type=branch
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap output -raw apply_role_arn | gh secret set AWS_APPLY_ROLE_ARN --env @ENV@ --repo @SLUG@
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap output -raw deploy_role_arn | gh secret set AWS_DEPLOY_ROLE_ARN --env @ENV@ --repo @SLUG@
     AWS_PROFILE=@PREFIX@-@ENV@-admin TF_DATA_DIR=.terraform-@ENV@ terraform -chdir=infra/terraform/bootstrap output -raw plan_role_arn | gh secret set AWS_PLAN_ROLE_ARN_@ENVUP@ --repo @SLUG@
     gh secret set AWS_ACCOUNT_ID --env @ENV@ --repo @SLUG@
     gh secret set AWS_ACCOUNT_ID_@ENVUP@ --repo @SLUG@
   The last two prompt: paste <ENV_ACCOUNT_ID> each time.
5. Wire the workflows (a reviewed diff; the parity guard checks it):
   a. .github/workflows/terraform-iac.yml: add the job below, and add @ENV@ to the options of the dispatch input env.
        plan-@ENV@:
          name: plan (@ENV@)
          needs: checks
          if: >-
            github.event_name == 'pull_request'
            && github.event.pull_request.head.repo.full_name == github.repository
            && github.event.pull_request.user.login != 'dependabot[bot]'
          permissions:
            contents: read
            id-token: write
            pull-requests: write
          uses: ./.github/workflows/reusable-terraform-plan.yml # zizmor: ignore[self-repository]
          with:
            env: @ENV@
          secrets:
            AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID_@ENVUP@ }}
            AWS_PLAN_ROLE_ARN: ${{ secrets.AWS_PLAN_ROLE_ARN_@ENVUP@ }}
   b. .github/workflows/terraform-destroy.yml: add @ENV@ to the options of the input env and to allowed_envs in the confirm job.
   A push to main still applies dev only; apply @ENV@ with Run workflow on terraform-iac. The function is created
   from an image that is already in the @ENV@ ECR repository (ADR 0012 L3), so push or promote an image first.
6. make check   (the parity guard names anything missing)
7. Open a pull request.
EOF
}

describe_plan() {
  local verb="created"
  if [ "$dry_run" = 1 ]; then verb="would create"; fi
  log "new environment '${env_name}' from '${from}'"
  log "${verb} infra/terraform/envs/${env_name}/ (tracked files of envs/${from}/)"
  log "  terraform.tfvars: env = \"${env_name}\""
  log "  backend.tf: key = \"envs/${env_name}/terraform.tfstate\""
  log "${verb} infra/terraform/bootstrap/accounts/${env_name}.tfvars.example"
  log "${verb} infra/terraform/bootstrap/accounts/${env_name}.tfvars (gitignored, mode 600, placeholders)"
}

if [ "$dry_run" = 1 ]; then
  describe_plan
  warn "dry run: nothing was written"
  print_next_steps
  exit 0
fi

# --- Build in temp paths next to the targets, then move in. The EXIT trap removes temps, and anything already moved
# in when a later move fails, so a failed run leaves no partial environment.
tmp_env="" tmp_example="" tmp_account="" moved=() committed=0
cleanup() {
  local p
  [ -z "$tmp_env" ] || rm -rf "$tmp_env"
  [ -z "$tmp_example" ] || rm -f "$tmp_example"
  [ -z "$tmp_account" ] || rm -f "$tmp_account"
  if [ "$committed" != 1 ] && [ ${#moved[@]} -gt 0 ]; then
    for p in "${moved[@]}"; do rm -rf "$p"; done
  fi
}
trap cleanup EXIT

tmp_env="$(mktemp -d "$envs_dir/.new-env.XXXXXX")" || die "cannot create a temp directory under infra/terraform/envs"
tmp_example="$(mktemp "$accounts_dir/.new-env.XXXXXX")" || die "cannot create a temp file under infra/terraform/bootstrap/accounts"
tmp_account="$(mktemp "$accounts_dir/.new-env.XXXXXX")" || die "cannot create a temp file under infra/terraform/bootstrap/accounts"

# The tracked files of the source root only: no .terraform/, no *.auto.tfvars, no local state or plan files.
tracked="$(git -C "$ROOT" ls-files -- "infra/terraform/envs/${from}")"
[ -n "$tracked" ] || die "git lists no tracked files under infra/terraform/envs/${from}"
while IFS= read -r rel; do
  [ -f "$ROOT/$rel" ] || die "tracked file ${rel} is missing on disk"
  sub="${rel#"infra/terraform/envs/${from}/"}"
  mkdir -p "$tmp_env/$(dirname "$sub")"
  cp -p "$ROOT/$rel" "$tmp_env/$sub"
done <<<"$tracked"
chmod 755 "$tmp_env"

# rewrite_value <file> <key> <value>: keep the text up to the value (key, spacing, `=`), write the new quoted value.
rewrite_value() {
  awk -v k="$2" -v v="$3" '
    $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") { match($0, /^[^=]*=[[:space:]]*/); print substr($0, 1, RLENGTH) "\"" v "\""; next }
    { print }' "$1" >"$1.new"
  mv "$1.new" "$1"
}

tfvars="$tmp_env/terraform.tfvars"
{
  printf '# Generated by scripts/tf/new-env.sh from envs/%s; review every value. Committed on purpose (FR-6):\n' "$from"
  printf '# environments differ only through this file. No account ID here; aws_account_id comes from\n'
  printf '# TF_VAR_aws_account_id (CI) or a gitignored *.auto.tfvars.\n'
  awk 'h == 0 && /^#/ { next } { h = 1; print }' "$tfvars"
} >"$tfvars.new"
mv "$tfvars.new" "$tfvars"
rewrite_value "$tfvars" env "$env_name"
rewrite_value "$tmp_env/backend.tf" key "envs/${env_name}/terraform.tfstate"

# The account inputs: the source example with its header and placeholders renamed. The bootstrap `env` defaults to dev,
# so the new file must set it, or the account would get dev's names.
{
  printf '# Copy to %s.tfvars (gitignored) and fill in. Never commit real values.\n' "$env_name"
  grep -v '^# Copy to ' "$src_example" | sed "s/<${from_up}_ACCOUNT_ID>/<${env_up}_ACCOUNT_ID>/g"
} >"$tmp_example"
example_env_count="$(key_count "$tmp_example" env)"
if [ "$example_env_count" = 1 ]; then
  rewrite_value "$tmp_example" env "$env_name"
elif [ "$example_env_count" = 0 ]; then
  printf '\n# The bootstrap default is dev: every other environment must set env.\nenv = "%s"\n' "$env_name" >>"$tmp_example"
else
  die "source format changed: env is assigned more than once in ${src_example#"$ROOT"/}; update scripts/tf/new-env.sh"
fi
cp "$tmp_example" "$tmp_account"
chmod 644 "$tmp_example"
chmod 600 "$tmp_account"

# Move in. The account file goes last, so an interrupted run has at most the two committed files to remove.
mv "$tmp_env" "$dst" || die "cannot create ${dst#"$ROOT"/}"
moved+=("$dst")
tmp_env=""
mv "$tmp_example" "$dst_example" || die "cannot create ${dst_example#"$ROOT"/}"
moved+=("$dst_example")
tmp_example=""
mv "$tmp_account" "$dst_account" || die "cannot create ${dst_account#"$ROOT"/}"
moved+=("$dst_account")
tmp_account=""
committed=1

describe_plan
ok "created envs/${env_name} (not committed: review it with git status)"
print_next_steps
