#!/usr/bin/env bash
# Grep-level Terraform policy rules that `terraform test` cannot express (ADR 0004, E28).
# Rules about files that do not exist yet (modules/, envs/) pass when those paths are absent.
# Comment lines (# or //) are ignored. Offline; never touches AWS.
#
# Usage: scripts/tf/policy.sh [root]   (default root: infra/terraform)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

root="${1:-$ROOT/infra/terraform}"
[ -d "$root" ] || die "root not found: $root"

failures=()

# fail <rule id> <message> <matching lines...>
fail() {
  local id="$1" msg="$2"
  shift 2
  failures+=("policy[$id] $msg")
  local line
  for line in "$@"; do printf '       %s\n' "$line" >&2; done
}

# scan <extended regex> <dir>: file:line:text of matching non-comment lines in *.tf under <dir>.
scan() {
  [ -d "$2" ] || return 0
  grep -rEn --include='*.tf' --exclude-dir=.terraform -e "$1" "$2" 2>/dev/null |
    grep -Ev '^[^:]+:[0-9]+:[[:space:]]*(#|//)' || true
}

# report <rule id> <message> <scan output>
report() {
  local out="$3" lines=() line
  [ -n "$out" ] || return 0
  while IFS= read -r line; do lines+=("${line#"$ROOT"/}"); done <<<"$out"
  fail "$1" "$2" "${lines[@]}"
}

# The patterns reach awk through the environment: `awk -v` would interpret backslashes (`\.` becomes `.`).
# scan_sources <block opener regex> <allowed source regex> <dir>...: file:line:text of every `source =` inside a block
# that is not allowed. awk follows the block by brace depth (grep level, no HCL parser); quoted strings and comment
# tails are cut before the braces are counted, so a `"}"` or `# }` cannot end the block early. A `source` on the
# same line as the opener counts.
scan_sources() {
  local opener="$1" allowed="$2" dir out=""
  shift 2
  for dir in "$@"; do
    [ -d "$dir" ] || continue
    out="$out$(
      # shellcheck disable=SC2016  # awk program, not shell
      find "$dir" -name '*.tf' -not -path '*/.terraform/*' -print0 |
        OPENER="$opener" ALLOWED="$allowed" xargs -0 awk '
          FNR == 1 { inblock = 0; depth = 0 }
          /^[[:space:]]*(#|\/\/)/ { next }
          BEGIN { opener = ENVIRON["OPENER"]; allowed = ENVIRON["ALLOWED"] }
          !inblock && $0 ~ opener { inblock = 1; depth = 0 }
          inblock {
            if (match($0, /(^|[^A-Za-z0-9_])source[[:space:]]*=[[:space:]]*/)) {
              rest = substr($0, RSTART + RLENGTH)
              if (rest !~ allowed) printf "%s:%d:%s\n", FILENAME, FNR, $0
            }
            code = $0
            gsub(/"[^"]*"/, "", code)
            sub(/#.*$/, "", code)
            sub(/\/\/.*$/, "", code)
            depth += gsub(/\{/, "{", code)
            depth -= gsub(/\}/, "}", code)
            if (depth <= 0) inblock = 0
          }
        ' 2>/dev/null || true
    )"$'\n'
  done
  printf '%s' "$out" | grep -v '^$' || true
}


# (1) FR-8: Terraform creates secret shells only, never values.
report 1 "aws_secretsmanager_secret_version is forbidden (secret values stay out of state)" \
  "$(scan '^[[:space:]]*resource[[:space:]]+"aws_secretsmanager_secret_version"' "$root")"

# (2) Security group rules are standalone resources so default_tags reach them.
report 2 "aws_security_group_rule is forbidden under modules/ (use aws_vpc_security_group_*_rule)" \
  "$(scan '^[[:space:]]*resource[[:space:]]+"aws_security_group_rule"' "$root/modules")"
report 2 "inline ingress/egress block under modules/ (use standalone rule resources)" \
  "$(scan '^[[:space:]]*(ingress|egress)[[:space:]]*\{' "$root/modules")"
report 2 "dynamic or list-valued ingress/egress under modules/ (use standalone rule resources)" \
  "$(scan '^[[:space:]]*(dynamic[[:space:]]+"(ingress|egress)"|(ingress|egress)[[:space:]]*=[[:space:]]*\[)' "$root/modules")"

# (3) Inline role policies only; no managed Lambda execution policy (AWSLambdaBasicExecutionRole allows
# logs:CreateLogGroup on *, ADR 0012 L9).
report 3 "AWSLambda*ExecutionRole managed policies are forbidden under modules/ (inline least-privilege policy)" \
  "$(scan 'AWSLambda[A-Za-z]*ExecutionRole' "$root/modules")"
report 3 "aws_iam_role_policy_attachment is forbidden under modules/ (inline policies only)" \
  "$(scan '^[[:space:]]*resource[[:space:]]+"aws_iam_role_policy_attachment"' "$root/modules")"

# (4) Every role under modules/ carries a permissions boundary.
if [ -d "$root/modules" ]; then
  missing="$(
    # shellcheck disable=SC2016  # awk program, not shell
    find "$root/modules" -name '*.tf' -not -path '*/.terraform/*' -print0 |
      xargs -0 awk '
        function flush() { if (inrole && !has) printf "%s:%d: resource aws_iam_role %s\n", file, start, name; inrole = 0 }
        FNR == 1 { flush(); file = FILENAME }
        /^[[:space:]]*#/ { next }
        /^resource[[:space:]]+"aws_iam_role"/ { flush(); inrole = 1; has = 0; start = FNR; name = $3; next }
        /^}/ { flush(); next }
        inrole && /^[[:space:]]*permissions_boundary[[:space:]]*=/ { has = 1 }
        END { flush() }
      ' 2>/dev/null || true
  )"
  report 4 "aws_iam_role without permissions_boundary under modules/" "$missing"
fi

# (5) Backends: the bucket (it holds the account ID) is never in a file; envs use the state key contract.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hit="$(grep -En '^[[:space:]]*bucket[[:space:]]*=' "$f" || true)"
  [ -z "$hit" ] || report 5 "bucket must not be set in backend.tf (pass -backend-config=bucket=...)" "$f:$hit"
done < <(find "$root" -name backend.tf -not -path '*/.terraform/*' 2>/dev/null)

if [ -d "$root/envs" ]; then
  for d in "$root"/envs/*/; do
    [ -d "$d" ] || continue
    env_dir="$(basename "$d")"
    f="${d}backend.tf"
    if [ ! -f "$f" ]; then
      if compgen -G "${d}*.tf" >/dev/null; then
        fail 5 "envs/$env_dir has Terraform files but no backend.tf" "${d#"$ROOT"/}"
      fi
      continue
    fi
    grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true' "$f" ||
      fail 5 "envs/$env_dir/backend.tf needs use_lockfile = true" "${f#"$ROOT"/}"
    grep -Eq "^[[:space:]]*key[[:space:]]*=[[:space:]]*\"envs/$env_dir/terraform.tfstate\"" "$f" ||
      fail 5 "envs/$env_dir/backend.tf needs key = \"envs/$env_dir/terraform.tfstate\"" "${f#"$ROOT"/}"
  done
fi

# (6) Modules inherit providers and backends from their root.
report 6 "provider or backend block under modules/ (modules take them from the root)" \
  "$(scan '^[[:space:]]*(provider|backend)[[:space:]]+"' "$root/modules")"

# (7) Role trust: a module role may only be assumed by a service principal (lambda.amazonaws.com). Grep level, not a
# policy parser: in any module directory that declares an aws_iam_role, no "AWS" or "Federated" principal type
# and no identifiers holding an ARN, :root or "*" may appear. Unquoted `AWS =` / `Federated =` keys and
# `Principal = "*"` / `type = "*"` count too. Cross-account or user trust would show up as one of those.
if [ -d "$root/modules" ]; then
  trust_out=""
  while IFS= read -r mdir; do
    [ -n "$mdir" ] || continue
    trust_out="$trust_out$(scan '("AWS"|"Federated"|(^|[^A-Za-z_])(AWS|Federated)[[:space:]]*=|Principal[[:space:]]*=[[:space:]]*"\*"|type[[:space:]]*=[[:space:]]*"\*"|identifiers[[:space:]]*=.*(arn:|:root|"\*"))' "$mdir")"$'\n'
  done < <(grep -rlE --include='*.tf' --exclude-dir=.terraform '^[[:space:]]*resource[[:space:]]+"aws_iam_role"[[:space:]]' "$root/modules" 2>/dev/null | xargs -n1 dirname 2>/dev/null | sort -u)
  trust_out="$(printf '%s' "$trust_out" | grep -v '^$' || true)"
  # No exemption: the one cross-account principal (the promotion pull of ADR 0008 P9) lives in the admin-applied
  # bootstrap/ecr.tf since ADR 0012 L4, and bootstrap is outside this rule.
  report 7 "role trust may only allow a service principal such as lambda.amazonaws.com (no AWS/Federated/wildcard principals, no arn: or :root identifiers)" "$trust_out"
fi

# (8) Root outputs are public in apply logs (repo is public): envs/*/outputs.tf never references an ARN,
# the ECR repository URL (it holds the account ID) or an account ID. Those stay module outputs.
if [ -d "$root/envs" ]; then
  out8=""
  for d in "$root"/envs/*/; do
    [ -f "${d}outputs.tf" ] || continue
    out8="$out8$(scan '(\.arn([^A-Za-z0-9_]|$)|_arn([^A-Za-z0-9_]|$)|repository_url|account_id)' "${d%/}")"$'\n'
  done
  out8="$(printf '%s' "$out8" | grep 'outputs\.tf:' || true)"
  report 8 "envs/*/outputs.tf must not reference .arn, _arn, repository_url or account_id (public apply logs)" "$out8"
fi

# (9) No code execution outside the providers (ADR 0006, I1): a provisioner or the external data source runs commands
# on the runner during plan or apply, with the CI role credentials in the environment.
# Labels may be quoted or bare (HCL accepts both), and the block may open mid-line (`resource ... { provisioner ... {`),
# so the match is not anchored at the line start.
for dir in "$root/modules" "$root/envs"; do
  report 9 "provisioner blocks are forbidden under modules/ and envs/ (they run commands on the CI runner)" \
    "$(scan '(^|[[:space:]{;])provisioner([[:space:]]+[A-Za-z0-9_-]+|[[:space:]]*"[A-Za-z0-9_-]+")[[:space:]]*\{' "$dir")"
  report 9 "data \"external\" is forbidden under modules/ and envs/ (it runs a program on the CI runner)" \
    "$(scan '(^|[[:space:]{;])data([[:space:]]+external|[[:space:]]*"external")"?[[:space:]{]' "$dir")"
done

# (10) No *.tf.json: the line based rules above read only *.tf, so a JSON twin of a file would bypass all of them
# (ADR 0007 S11).
tf_json="$(find "$root" -name '*.tf.json' -not -path '*/.terraform/*' 2>/dev/null | sort || true)"
report 10 "*.tf.json is forbidden under infra/terraform (the policy rules read only *.tf)" "$tf_json"

# (11) Module sources under envs/ and modules/ are local paths: a registry or git source would run unreviewed code
# with the CI role credentials.
report 11 "module source must be a local path (./ or ../) under modules/ and envs/" \
  "$(scan_sources '^[[:space:]]*module[[:space:]]+"?[A-Za-z0-9_-]+"?[[:space:]]*\{' '^"\.\.?/' "$root/modules" "$root/envs")"

# (12) Provider sources are hashicorp/*: a third-party provider is code that runs with the CI role credentials. Covers
# bootstrap too.
report 12 "required_providers source must be hashicorp/* under bootstrap/, modules/ and envs/" \
  "$(scan_sources '^[[:space:]]*required_providers[[:space:]]*\{' '^"hashicorp/' "$root/bootstrap" "$root/modules" "$root/envs")"

if [ ${#failures[@]} -gt 0 ]; then
  for f in "${failures[@]}"; do printf '  - %s\n' "$f" >&2; done
  die "${#failures[@]} Terraform policy violation(s)"
fi
ok "terraform policy rules pass"
