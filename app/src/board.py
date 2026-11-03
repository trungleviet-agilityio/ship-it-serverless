"""Ship-it Board: tiny stdlib HTTP app for the ship-it-safely lab."""

import hashlib
import hmac
import html
import json
import os
import signal
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

STARTED = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


def image_digest() -> str:
    """Image digest from the ECS task metadata endpoint, or n/a on any error."""
    uri = os.environ.get("ECS_CONTAINER_METADATA_URI_V4")
    if not uri:
        return "n/a"
    try:
        # The URI is set by the ECS agent, not by a request, so the scheme is trusted.
        with urllib.request.urlopen(uri, timeout=1) as r:  # noqa: S310
            return str(json.loads(r.read()).get("ImageID") or "n/a")
    except Exception:
        return "n/a"


def color() -> str:
    explicit = os.environ.get("APP_COLOR")
    if explicit:
        return explicit
    hue = int(hashlib.sha256(os.environ.get("GIT_SHA", "local").encode()).hexdigest(), 16) % 360
    return f"hsl({hue}, 60%, 85%)"


def page() -> str:
    key_set = "yes" if os.environ.get("APP_API_KEY") else "no"
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
            expected = os.environ.get("APP_API_KEY", "").encode()
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
    # 0.0.0.0 so the container port is reachable from Docker and the ALB.
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)  # noqa: S104


def main() -> None:
    server = make_server(int(os.environ.get("PORT", "8080")))
    # shutdown() blocks until serve_forever() returns, so run it off the main thread.
    # As PID 1 the default SIGTERM action is ignored, so without this ECS waits for SIGKILL.
    signal.signal(
        signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start()
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
