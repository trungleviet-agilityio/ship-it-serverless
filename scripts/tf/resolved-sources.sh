#!/usr/bin/env bash
# Fail-closed check of what `terraform init` actually resolved (ADR 0007 fix round 2). The text rules in tf/policy.sh
# (11 and 12) give fast feedback, but escaped quotes, heredocs and /* */ comments can fool a line scanner. Terraform
# itself cannot be fooled about where code comes from:
#   - every module in <data dir>/modules/modules.json (the root entry, Key "", excluded) has a local source
#     (./ or ../);
#   - every provider in <dir>/.terraform.lock.hcl is registry.terraform.io/hashicorp/*.
# A directory with no modules has no modules.json, which is fine. A missing lock file is not: init writes one.
#
# Usage: scripts/tf/resolved-sources.sh <terraform dir> <TF_DATA_DIR used for init>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 2 ] || die "usage: scripts/tf/resolved-sources.sh <terraform dir> <TF_DATA_DIR used for init>"
dir="$1" data_dir="$2"
require_cmd jq "install jq"

bad=()

modules="$data_dir/modules/modules.json"
if [ -f "$modules" ]; then
  while IFS= read -r source; do
    case "$source" in
      ./* | ../*) ;;
      *) bad+=("module source is not local: $source") ;;
    esac
  done < <(jq -r '.Modules[] | select(.Key != "") | .Source' "$modules")
fi

lock="$dir/.terraform.lock.hcl"
[ -f "$lock" ] || die "no .terraform.lock.hcl in $dir (run terraform init first)"
while IFS= read -r provider; do
  case "$provider" in
    registry.terraform.io/hashicorp/*) ;;
    *) bad+=("provider is not hashicorp: $provider") ;;
  esac
done < <(sed -nE 's/^provider "([^"]*)".*/\1/p' "$lock")

if [ ${#bad[@]} -gt 0 ]; then
  for b in "${bad[@]}"; do printf '  - %s\n' "$b" >&2; done
  die "${#bad[@]} resolved source violation(s) in ${dir#"$ROOT"/}"
fi
ok "resolved modules are local and providers are hashicorp: ${dir#"$ROOT"/}"
