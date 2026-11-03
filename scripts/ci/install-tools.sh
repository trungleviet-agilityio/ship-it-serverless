#!/usr/bin/env bash
# Install CI tools with checksum verification (NFR-3, ADR 0004 E29, ADR 0005 F8, F12, F22).
# Tools: terraform, tflint, trivy, hadolint, crane. With no tool arguments, terraform and tflint are installed.
# Versions come from mise.toml (one source of truth). Each download is saved under a versioned file name and
# checked against scripts/ci/tools.sha256, so a version bump without a checksum update fails with
# "no checksum for <file>". Neither hashicorp/setup-terraform nor trivy-action/setup-trivy is used: they do not
# verify the download (or, for trivy, were compromised in March 2026, GHSA-69fq-xp46-6x23).
# Providers are verified later by `terraform init -lockfile=readonly`; tflint verifies its own plugin download.
#
# Usage: scripts/ci/install-tools.sh <dest dir> [terraform|tflint|trivy|hadolint|crane ...]
# Exit codes: 0 installed, 1 unknown tool, missing checksum or checksum mismatch.
# Test overrides (scratch copies only): CI_TOOLS_MISE_TOML, CI_TOOLS_SHA256, and CI_TOOLS_BASE_URL (a URL prefix such
# as file:///dir holding the files under their versioned names, used instead of the release URLs).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

known_tools="terraform tflint trivy hadolint crane"

[ $# -ge 1 ] || die "usage: scripts/ci/install-tools.sh <dest dir> [${known_tools// /|} ...]"
dest="$1"
shift

tools=(terraform tflint)
if [ $# -gt 0 ]; then
  tools=("$@")
fi
for tool in "${tools[@]}"; do
  case " $known_tools " in
    *" $tool "*) ;;
    *) die "unknown tool '$tool' (known: $known_tools)" ;;
  esac
done

mise_toml="${CI_TOOLS_MISE_TOML:-$ROOT/mise.toml}"
sums="${CI_TOOLS_SHA256:-$ROOT/scripts/ci/tools.sha256}"
[ -f "$mise_toml" ] || die "mise.toml not found: $mise_toml"
[ -f "$sums" ] || die "checksum file not found: $sums"

require_cmd curl "apt-get install curl"

# tool_version <name>: the pinned version from mise.toml.
tool_version() {
  local v
  v="$(sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"([0-9][^\"]*)\".*/\1/p" "$mise_toml" | head -n1)"
  [ -n "$v" ] || die "$1 is not pinned in ${mise_toml##*/}"
  printf '%s' "$v"
}

# tool_spec <tool> <version>: sets `file` (the versioned name in ci/tools.sha256), `url` and `kind`
# (zip and tar.gz hold one binary named after the tool; raw is the binary itself). One row per tool.
tool_spec() {
  local tool="$1" v="$2"
  case "$tool" in
    terraform)
      kind=zip file="terraform_${v}_linux_amd64.zip"
      url="https://releases.hashicorp.com/terraform/${v}/terraform_${v}_linux_amd64.zip" ;;
    tflint)
      kind=zip file="tflint_${v}_linux_amd64.zip"
      url="https://github.com/terraform-linters/tflint/releases/download/v${v}/tflint_linux_amd64.zip" ;;
    trivy)
      kind=tar file="trivy_${v}_Linux-64bit.tar.gz"
      url="https://github.com/aquasecurity/trivy/releases/download/v${v}/trivy_${v}_Linux-64bit.tar.gz" ;;
    crane)
      kind=tar file="crane_${v}_Linux_x86_64.tar.gz"
      url="https://github.com/google/go-containerregistry/releases/download/v${v}/go-containerregistry_Linux_x86_64.tar.gz" ;;
    hadolint)
      kind=raw file="hadolint_${v}_linux_x86_64"
      url="https://github.com/hadolint/hadolint/releases/download/v${v}/hadolint-linux-x86_64" ;;
  esac
}

# checksum_line <file>: the checked-in line for that exact file name, or fail before anything is downloaded.
checksum_line() {
  local line
  line="$(grep -E "^[0-9a-f]{64}  ${1//./\\.}\$" "$sums" || true)"
  [ -n "$line" ] || die "no checksum for $1 in ${sums##*/}; add the official SHA-256 after reviewing the release"
  printf '%s' "$line"
}

# sha256_check <dir> <file>: verify <file> in <dir> against the checked-in line.
sha256_check() {
  local dir="$1" file="$2" line sum_cmd="sha256sum"
  line="$(checksum_line "$file")"
  command -v sha256sum >/dev/null 2>&1 || sum_cmd="shasum -a 256"
  # shellcheck disable=SC2086  # sum_cmd is one of two fixed commands
  (cd "$dir" && printf '%s\n' "$line" | $sum_cmd -c - >/dev/null) || die "checksum mismatch for $file"
  ok "$file matches ${sums##*/}"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"

# install_tool <tool>: download, verify, unpack into $dest.
install_tool() {
  local tool="$1" kind file url
  tool_spec "$tool" "$(tool_version "$tool")"
  checksum_line "$file" >/dev/null
  log "download $file"
  if [ -n "${CI_TOOLS_BASE_URL:-}" ]; then url="${CI_TOOLS_BASE_URL%/}/$file"; fi
  curl -fsSL --retry 3 -o "$work/$file" "$url"
  sha256_check "$work" "$file"
  case "$kind" in
    zip) require_cmd unzip "apt-get install unzip"; unzip -q -o "$work/$file" "$tool" -d "$dest" ;;
    tar) require_cmd tar "apt-get install tar"; tar -xzf "$work/$file" -C "$dest" "$tool" ;;
    raw) cp "$work/$file" "$dest/$tool" ;;
  esac
  chmod +x "$dest/$tool"
}

for tool in "${tools[@]}"; do
  install_tool "$tool"
done

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$(cd "$dest" && pwd)" >>"$GITHUB_PATH"
fi

# The binaries are linux_amd64; on another OS they were only verified and unpacked.
if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
  for tool in "${tools[@]}"; do
    "$dest/$tool" --version >&2 || "$dest/$tool" version >&2
  done
else
  warn "not linux x86_64: tools verified and unpacked, version check skipped"
fi
ok "installed ${tools[*]} into $dest"
