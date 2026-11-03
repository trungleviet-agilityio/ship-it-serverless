"""Ship-it Board: tiny stdlib HTTP app for the ship-it-serverless lab."""

import hashlib
import hmac
import html
import json
import os
import re
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import aws_sigv4

STARTED = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
# A failed secret read is retried after this many seconds, so one cold-start error (throttling, a
# network blip, an IAM change still propagating) does not leave the environment without a key.
SECRET_RETRY_SECONDS = 60.0
# Tests point the Secrets Manager call at a local fake server; None means the regional endpoint.
_SECRETS_ENDPOINT: str | None = None
_secret_lock = threading.Lock()
# arn -> (value, monotonic time of the read); a failure is cached as "" with its time.
_secret_cache: dict[str, tuple[str, float]] = {}


def image_digest() -> str:
    """IMAGE_DIGEST set by the deploy before PublishVersion (ADR 0012 L6), or n/a."""
    value = os.environ.get("IMAGE_DIGEST", "")
    return value if DIGEST_RE.fullmatch(value) else "n/a"


def api_key() -> str:
    """APP_API_KEY if set (local, tests), else the secret read once with the execution role."""
    local = os.environ.get("APP_API_KEY")
    if local:
        return local
    arn = os.environ.get("APP_API_KEY_SECRET_ARN")
    if not arn:
        return ""
    with _secret_lock:
        cached = _secret_cache.get(arn)
        if cached and (cached[0] or time.monotonic() - cached[1] < SECRET_RETRY_SECONDS):
            return cached[0]
        creds = aws_sigv4.Credentials(
            os.environ.get("AWS_ACCESS_KEY_ID", ""),
            os.environ.get("AWS_SECRET_ACCESS_KEY", ""),
            os.environ.get("AWS_SESSION_TOKEN", ""),
        )
        region = os.environ.get("AWS_REGION", "")
        try:
            value = aws_sigv4.get_secret_value(arn, region, creds, endpoint=_SECRETS_ENDPOINT)
        except Exception as e:  # best effort: a failed read means secret_loaded: no and 401
            # Class name only: the message could echo the ARN or response details.
            print(f"secret read failed: {type(e).__name__}", flush=True)
            value = ""
        _secret_cache[arn] = (value, time.monotonic())
        return value


def color() -> str:
    explicit = os.environ.get("APP_COLOR")
    if explicit:
        return explicit
    hue = int(hashlib.sha256(os.environ.get("GIT_SHA", "local").encode()).hexdigest(), 16) % 360
    return f"hsl({hue}, 60%, 85%)"


def page() -> str:
    key_set = "yes" if api_key() else "no"
    promoted = os.environ.get("APP_ENV") == "prod"
    shipped_by = "app-promote (dev digest)" if promoted else "app-deploy (digest-pinned)"
    rows = [
        ("APP_ENV", os.environ.get("APP_ENV", "unknown")),
        ("GIT_SHA", os.environ.get("GIT_SHA", "unknown")),
        ("started", STARTED),
        ("image digest", image_digest()),
        ("shipped by", shipped_by),
        ("secret_loaded: " + key_set, ""),
    ]
    body = "".join(f"<p>{html.escape(': '.join(r) if r[1] else r[0])}</p>" for r in rows)
    background = html.escape(color(), quote=True)
    return (
        '<!doctype html><html><head><meta charset="utf-8"><title>Ship-it Board</title></head>'
        f'<body style="font-family:sans-serif;background:{background}">'
        f"<h1>Ship-it Board</h1>{body}</body></html>"
    )


class Handler(BaseHTTPRequestHandler):
    def send(self, status: int, body: str, ctype: str = "application/json") -> None:
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/":
            self.send(200, page(), "text/html")
        elif path == "/health":
            broken = os.environ.get("BREAK", "").lower() == "true"
            self.send(500 if broken else 200, json.dumps({"status": "error" if broken else "ok"}))
        elif path == "/version":
            self.send(
                200,
                json.dumps(
                    {
                        "env": os.environ.get("APP_ENV", "unknown"),
                        "git_sha": os.environ.get("GIT_SHA", "unknown"),
                        "image_digest": image_digest(),
                    }
                ),
            )
        elif path == "/admin":
            expected = api_key().encode()
            given = self.headers.get("X-API-Key", "").encode()
            if expected and hmac.compare_digest(given, expected):
                self.send(200, json.dumps({"admin": "ok"}))
            else:
                self.send(401, json.dumps({"error": "unauthorized"}))
        else:
            self.send(404, json.dumps({"error": "not found"}))

    def log_message(self, format: str, *args: Any) -> None:
        # Log only method, path and status. Never headers (X-API-Key).
        print(f"{self.client_address[0]} {format % args}", flush=True)


def make_server(port: int) -> ThreadingHTTPServer:
    # 0.0.0.0 so the port is reachable from Docker; on Lambda the Web Adapter calls it locally.
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)  # noqa: S104


def main() -> None:
    server = make_server(int(os.environ.get("PORT", "8080")))
    # shutdown() blocks until serve_forever() returns, so run it off the main thread.
    # As PID 1 the default SIGTERM action is ignored, so without this `docker stop` waits for KILL.
    signal.signal(
        signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start()
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
