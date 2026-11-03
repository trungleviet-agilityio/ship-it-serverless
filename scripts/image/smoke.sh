#!/usr/bin/env bash
# Run the app image the way Fargate runs it and check it (ADR 0005, F11): read-only root, UID 10001, a /tmp that is
# owned by root and not writable by that user, no capabilities, no new privileges. Needs Docker, curl and jq.
#
# Asserts: the image user is 10001:10001; GET /health is 200; GET /version git_sha equals the argument; GET / shows
# secret_loaded: yes and never the fake key; GET /admin without the key is 401; `docker stop -t 10` takes at most
# 5 seconds and the app exits with code 0 (needs the SIGTERM handler, F20).
#
# Usage: scripts/image/smoke.sh <image> <commit sha>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 2 ] || die "usage: scripts/image/smoke.sh <image> <commit sha>"
image="$1" sha="$2"
require_cmd docker "install Docker"
require_cmd curl "apt-get install curl"
require_cmd jq "brew install jq"

name="${PROJECT_PREFIX}-smoke-$$"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A fake key made at run time: it is not a secret, but the page must still never show it.
fake_key="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

user="$(docker image inspect --format '{{.Config.User}}' "$image")"
[ "$user" = "10001:10001" ] || die "image user is '$user', expected 10001:10001"

log "start $image like Fargate"
docker run -d --name "$name" --read-only --user 10001:10001 \
  --tmpfs /tmp:rw,mode=0755,uid=0,gid=0 --cap-drop ALL --security-opt no-new-privileges \
  -e APP_ENV=ci -e "APP_API_KEY=${fake_key}" -p 127.0.0.1::8080 "$image" >/dev/null
port="$(docker port "$name" 8080/tcp | head -n1 | sed -E 's/.*:([0-9]+)$/\1/')"
base="http://127.0.0.1:${port}"

# show_logs: container output helps when a check fails. The app logs method, path and status only.
show_logs() {
  warn "container log (last lines):"
  docker logs --tail 20 "$name" >&2 || true
}

up=0
for _ in $(seq 1 30); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/health" || true)" = "200" ]; then
    up=1
    break
  fi
  # A container that already exited will never answer.
  [ "$(docker inspect --format '{{.State.Running}}' "$name")" = "true" ] || break
  sleep 1
done
if [ "$up" -ne 1 ]; then
  show_logs
  die "GET /health did not return 200 within 30 s (does the app write to a read-only path?)"
fi
ok "GET /health is 200"

got_sha="$(curl -fsS "$base/version" | jq -r '.git_sha')"
[ "$got_sha" = "$sha" ] || die "GET /version git_sha is '$got_sha', expected '$sha'"
ok "GET /version shows the commit"

page="$(curl -fsS "$base/")"
case "$page" in
  *"secret_loaded: yes"*) ok "GET / shows secret_loaded: yes" ;;
  *) die "GET / does not show 'secret_loaded: yes'" ;;
esac
case "$page" in
  *"$fake_key"*) die "GET / shows the API key" ;;
esac

code="$(curl -s -o /dev/null -w '%{http_code}' "$base/admin" || true)"
[ "$code" = "401" ] || die "GET /admin without the key returned $code, expected 401"
ok "GET /admin without the key is 401"

# A crash after start (for example a write to the read-only root) shows up here as a stopped container.
[ "$(docker inspect --format '{{.State.Running}}' "$name")" = "true" ] || {
  show_logs
  die "the container stopped by itself"
}

start="$SECONDS"
docker stop -t 10 "$name" >/dev/null
took=$((SECONDS - start))
exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$name")"
[ "$took" -le 5 ] || die "docker stop took ${took}s (limit 5s): the app ignores SIGTERM (ADR 0005, F20)"
[ "$exit_code" = "0" ] || die "the app exited with code $exit_code after SIGTERM, expected 0"
ok "stopped in ${took}s with exit code 0"
