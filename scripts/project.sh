#!/usr/bin/env bash
# The project prefix (project.env) and its copies. Scripts read project.env through lib.sh; a few files cannot, so they
# hold a copy that this script keeps equal:
#   infra/terraform/bootstrap/variables.tf   the default of variable "prefix"
#   infra/terraform/envs/*/terraform.tfvars  prefix = "..."
#   .github/workflows/*.yml                  the state bucket host <prefix>-${{ env.ENV }}-tfstate-... (harden-runner
#                                            reads its allowlist before checkout, so it cannot run a script)
#   app/compose.yaml                         the local image <prefix>-app:local
#
#   scripts/project.sh check [repo root]           fail when a copy differs from project.env (make lint)
#   scripts/project.sh set <prefix> [repo root]    write the prefix to project.env and every copy (make set-prefix)
#
# Set the prefix once, in a fresh fork, before the first bootstrap. On a live project a new prefix names new resources:
# nothing in AWS is renamed.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: scripts/project.sh check [repo root] | scripts/project.sh set <prefix> [repo root]"
[ $# -ge 1 ] || die "$usage"
mode="$1"
shift
case "$mode" in
  check) [ $# -le 1 ] || die "$usage"; root="${1:-$ROOT}" ;;
  set) [ $# -ge 1 ] && [ $# -le 2 ] || die "$usage"; new="$1"; root="${2:-$ROOT}" ;;
  *) die "$usage" ;;
esac

BOOTSTRAP_VARS="infra/terraform/bootstrap/variables.tf"
COMPOSE="app/compose.yaml"
# The workflow copy: the prefix in front of the state bucket host.
BUCKET_HOST_RE='([a-z][a-z0-9]*)-\$\{\{ env\.ENV \}\}-tfstate-'

# The files that hold a copy, relative to the root (bash 3.2: no mapfile).
copy_files() {
  printf '%s\n' "$BOOTSTRAP_VARS" "$COMPOSE"
  (cd "$root" && find infra/terraform/envs -mindepth 2 -maxdepth 2 -name terraform.tfvars && grep -El "$BUCKET_HOST_RE" .github/workflows/*.yml) | sort
}

# prefixes_in <file>: print every prefix copy the file holds, one per line.
prefixes_in() {
  case "$1" in
    "$BOOTSTRAP_VARS") awk '/^variable "prefix"/ { in_block = 1 } in_block && /^}/ { in_block = 0 }
      in_block && match($0, /default[[:space:]]*=[[:space:]]*"[^"]*"/) { v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); print v }' "$root/$1" ;;
    "$COMPOSE") sed -nE 's/^[[:space:]]*image:[[:space:]]*([a-z0-9]+)-app:local[[:space:]]*$/\1/p' "$root/$1" ;;
    *.tfvars) sed -nE 's/^prefix[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$root/$1" ;;
    *) grep -oE "$BUCKET_HOST_RE" "$root/$1" | sed -E 's/-\$\{\{.*//' ;;
  esac
}

# rewrite <file> <sed expression>: edit in place without GNU or BSD sed -i.
rewrite() {
  local out
  out="$(mktemp)"
  sed -E "$2" "$root/$1" >"$out"
  cat "$out" >"$root/$1"
  rm -f "$out"
}

check() {
  local want file found problems=0
  want="$(sed -n 's/^PREFIX=//p' "$root/project.env" 2>/dev/null || true)"
  [[ "$want" =~ $PREFIX_RE ]] || die "project.env must set PREFIX to 2 to 10 lowercase letters or digits, starting with a letter"
  while IFS= read -r file; do
    found="$(prefixes_in "$file")"
    if [ -z "$found" ]; then
      warn "$file: no prefix copy found"
      problems=$((problems + 1))
    elif [ -n "$(grep -vxF "$want" <<<"$found" || true)" ]; then
      warn "$file: prefix $(sort -u <<<"$found" | tr '\n' ' ')differs from project.env ($want)"
      problems=$((problems + 1))
    fi
  done < <(copy_files)
  [ "$problems" -eq 0 ] || die "$problems file(s) disagree with project.env; run make set-prefix PREFIX=$want"
  ok "every prefix copy matches project.env ($want)"
}

set_prefix() {
  local file
  [[ "$new" =~ $PREFIX_RE ]] || die "the prefix must be 2 to 10 lowercase letters or digits, starting with a letter, got '$new'"
  rewrite project.env "s/^PREFIX=.*/PREFIX=${new}/"
  while IFS= read -r file; do
    case "$file" in
      "$BOOTSTRAP_VARS") rewrite "$file" "/^variable \"prefix\"/,/^}/ s/(default[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"${new}\"/" ;;
      "$COMPOSE") rewrite "$file" "s/^([[:space:]]*image:[[:space:]]*)[a-z0-9]+-app:local/\\1${new}-app:local/" ;;
      *.tfvars) rewrite "$file" "s/^(prefix[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"${new}\"/" ;;
      *) rewrite "$file" "s/[a-z][a-z0-9]*(-\\$\\{\\{ env\\.ENV \\}\\}-tfstate-)/${new}\\1/g" ;;
    esac
  done < <(copy_files)
  check
  warn "Docs, ADRs and diagrams still name the old prefix as history; terraform-docs tables update with make docs."
}

case "$mode" in
  check) check ;;
  set) set_prefix ;;
esac
