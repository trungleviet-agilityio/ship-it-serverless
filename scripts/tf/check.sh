#!/usr/bin/env bash
# Offline Terraform checks for every root and module under infra/terraform (ADR 0001, D12):
# a README.md with terraform-docs markers (D16), fmt, init without a backend, validate, and `terraform test`
# where test files exist. Runs scripts/tf/policy.sh first (ADR 0004, E28).
# Each directory gets its own temporary TF_DATA_DIR (ADR 0004, E27), so a real `init` against S3 in a checkout
# (a `.terraform/` next to the config) is never read or written and cannot make these checks ask for AWS.
# Never plans or applies: no AWS credentials are needed or used.
#
# Usage: scripts/tf/check.sh [dir ...]   (default: every directory holding *.tf)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

require_cmd terraform "brew install hashicorp/tap/terraform"

tf_root="$ROOT/infra/terraform"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$tmp_root/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

dirs=()
failed=()
if [ $# -gt 0 ]; then
  for d in "$@"; do dirs+=("$d"); done
else
  while IFS= read -r d; do dirs+=("$d"); done < <(
    find "$tf_root" -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u
  )
fi

if [ ${#dirs[@]} -eq 0 ]; then
  warn "no Terraform files under ${tf_root#"$ROOT"/} yet, nothing to check"
  exit 0
fi

log "terraform policy rules"
"$ROOT/scripts/tf/policy.sh" "$tf_root"

# D16: every root and module documents itself. The tables between the markers come from terraform-docs.
for dir in "${dirs[@]}"; do
  readme="$dir/README.md"
  if [ ! -f "$readme" ]; then
    failed+=("${dir#"$ROOT"/} (README.md missing)")
  elif ! grep -q 'BEGIN_TF_DOCS' "$readme"; then
    failed+=("${dir#"$ROOT"/} (README.md has no BEGIN_TF_DOCS marker)")
  fi
done

log "terraform fmt -check"
terraform fmt -check -recursive "$tf_root" || die "unformatted files; run: terraform fmt -recursive infra/terraform"

for dir in "${dirs[@]}"; do
  name="${dir#"$ROOT"/}"
  log "$name"
  data_dir="$tmp_root/data/$(printf '%s' "$name" | tr '/' '_')"
  mkdir -p "$data_dir"
  export TF_DATA_DIR="$data_dir"
  # Each step is guarded so one broken directory does not hide the rest; the summary fails the run.
  if ! terraform -chdir="$dir" init -backend=false -input=false >/dev/null; then
    failed+=("$name (init)")
    continue
  fi
  # What init resolved, not what the text says: remote modules and non-hashicorp providers fail here (ADR 0007).
  if ! "$ROOT/scripts/tf/resolved-sources.sh" "$dir" "$data_dir"; then
    failed+=("$name (resolved sources)")
    continue
  fi
  if ! terraform -chdir="$dir" validate -no-color >/dev/null; then
    failed+=("$name (validate)")
    continue
  fi
  if compgen -G "$dir/*.tftest.hcl" >/dev/null || compgen -G "$dir/tests/*.tftest.hcl" >/dev/null; then
    if ! terraform -chdir="$dir" test; then
      failed+=("$name (test)")
      continue
    fi
  fi
  ok "$name"
done

if [ ${#failed[@]} -gt 0 ]; then
  for f in "${failed[@]}"; do printf '  - %s\n' "$f" >&2; done
  die "${#failed[@]} Terraform check(s) failed"
fi
ok "all ${#dirs[@]} Terraform directories pass"
