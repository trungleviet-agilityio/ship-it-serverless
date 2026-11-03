# shellcheck shell=bash disable=SC2034  # the variables are read by the area files that source this one
# Shared setup of the CI helper self-tests (scripts/selftest/*.sh): the scratch directory, expect_fail, the shared
# fixture values and the stub aws, docker and terraform commands. Source it; do not run it.
# Written for bash 3.2, like lib.sh.

# The fixtures name resources with the prefix sis, so the self-tests pass whatever project.env holds (a fork).
export PROJECT_PREFIX=sis
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect_fail <label> <expected stderr text> <command...>: also leaves the output of the command in EXPECT_OUT, so a
# caller can inspect it (for a leaked host, say) without running the command a second time.
EXPECT_OUT=""
expect_fail() {
  local label="$1" text="$2" out rc=0
  shift 2
  # The ERR trap from lib.sh would print a second error inside the subshell; the exit code is checked here.
  out="$(
    trap - ERR
    "$@" 2>&1
  )" || rc=$?
  EXPECT_OUT="$out"
  [ "$rc" -ne 0 ] || die "selftest: $label should have failed"
  case "$out" in
    *"$text"*) ok "$label fails as expected" ;;
    *) die "selftest: $label failed without '$text': $out" ;;
  esac
}

# Fixture values, built at run time so no file holds a 12-digit literal (the account-ID hook scans them).
# acct is the AWS documentation account; leak_id is a number the hook and the guards must catch.
acct=123456789012
leak_id="$(printf '%s%s' 210987 654321)"
digest="$(printf 'a%.0s' $(seq 1 64))"
commit="$(printf 'b%.0s' $(seq 1 40))"
image="${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@sha256:${digest}"

# --- Stub aws, docker, gh, crane and terraform: file-driven replies, so the scripts that call them run offline.
# The stub answers a call from files in $sd: <key>.out (stdout), <key>.err (stderr) and <key>.rc (exit code, default
# 0). A suffix .N applies to the N-th call only (0-based). The key is aws-<service>-<operation>, gh-<group>-<command>
# (gh-run-list, gh-run-view), docker-<command>, or crane-<command> (crane-digest-src for a repository named
# sis-dev-app, crane-digest-tgt for any other, crane-copy, crane-auth). docker and crane also record the
# DOCKER_CONFIG they ran with in docker-config, and crane fails when it is not an existing directory, as it would
# without a login directory. Terraform is only logged (calls), never answered.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/aws" <<'EOF'
#!/usr/bin/env bash
dir="${STUB_DIR:?}" name="$(basename "$0")"
key="$name-$1"
case "$name" in aws | gh) key="$key-$2" ;; esac
if [ "$key" = crane-digest ]; then
  case "$2" in *sis-dev-app*) key=crane-digest-src ;; *) key=crane-digest-tgt ;; esac
fi
n="$(cat "$dir/$key.n" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$dir/$key.n"
echo "$name $*" >>"$dir/calls"
case "$name" in docker | crane) echo "${DOCKER_CONFIG:-}" >>"$dir/docker-config" ;; esac
if [ "$name" = crane ] && [ ! -d "${DOCKER_CONFIG:-}" ]; then echo "no DOCKER_CONFIG directory" >&2; exit 9; fi
case "$key" in docker-login | crane-auth) cat >/dev/null ;; esac
[ "$key" = docker-save ] && printf 'image tar' >"$3"
pick() { if [ -f "$dir/$key.$1.$n" ]; then echo "$dir/$key.$1.$n"; elif [ -f "$dir/$key.$1" ]; then echo "$dir/$key.$1"; fi; }
f="$(pick out)"; [ -z "$f" ] || cat "$f"
f="$(pick err)"; [ -z "$f" ] || cat "$f" >&2
f="$(pick rc)"; [ -z "$f" ] || exit "$(cat "$f")"
exit 0
EOF
chmod +x "$tmp/stub/aws"
cp "$tmp/stub/aws" "$tmp/stub/docker"
cp "$tmp/stub/aws" "$tmp/stub/gh"
cp "$tmp/stub/aws" "$tmp/stub/crane"
cat >"$tmp/stub/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >>"${STUB_DIR:?}/calls"
EOF
chmod +x "$tmp/stub/terraform"
sd=""
# stub_reset: a fresh reply directory. stub <key> <out|err|rc> <content> [call number]: set one reply.
stub_reset() { sd="$(mktemp -d "$tmp/stub-replies.XXXXXX")"; }
stub() { printf '%s' "$3" >"$sd/$1.$2${4:+.$4}"; }
# stubbed <command...>: run with the stubs first on PATH.
stubbed() { env PATH="$tmp/stub:$PATH" STUB_DIR="$sd" "$@"; }
# calls_have <text>: did the stubs see a call containing it?
calls_have() { grep -qF -- "$1" "$sd/calls" 2>/dev/null; }
