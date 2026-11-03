"""Tests for the Ship-it Board. Run from app/: python -m unittest discover -s tests"""

import contextlib
import io
import json
import os
import signal
import socket
import subprocess  # noqa: S404
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import board  # noqa: E402
from test_aws_sigv4 import FakeSecretsManager  # noqa: E402

KEY = "fake-test-key-123"
DIGEST = "sha256:" + "ab" * 32
ARN = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:sis-dev-app-key-AbCdEf"
REAL_URLOPEN = urllib.request.urlopen


def get(port: int, path: str, headers: dict[str, str] | None = None) -> tuple[int, str]:
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers or {})
    try:
        with REAL_URLOPEN(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class BoardTest(unittest.TestCase):
    env = {"APP_ENV": "test", "GIT_SHA": "abc1234", "APP_API_KEY": KEY}

    def setUp(self) -> None:
        patcher = mock.patch.dict(os.environ, self.env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.server = board.make_server(0)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def test_index(self) -> None:
        status, body = get(self.port, "/")
        self.assertEqual(status, 200)
        for text in ("test", "abc1234", "secret_loaded: yes", "n/a", "shipped by: app-deploy"):
            self.assertIn(text, body)
        self.assertNotIn(KEY, body)

    def test_index_prod_shipped_by_promote(self) -> None:
        with mock.patch.dict(os.environ, {"APP_ENV": "prod"}):
            self.assertIn("shipped by: app-promote", get(self.port, "/")[1])

    def test_index_secret_not_loaded(self) -> None:
        with mock.patch.dict(os.environ, {"APP_API_KEY": ""}):
            self.assertIn("secret_loaded: no", get(self.port, "/")[1])

    def test_index_escapes_html(self) -> None:
        with mock.patch.dict(os.environ, {"APP_ENV": "<script>x</script>"}):
            body = get(self.port, "/")[1]
        self.assertNotIn("<script>x", body)
        self.assertIn("&lt;script&gt;", body)

    def test_color_override_and_derived(self) -> None:
        with mock.patch.dict(os.environ, {"APP_COLOR": "#123456"}):
            self.assertIn("#123456", get(self.port, "/")[1])
        self.assertIn("hsl(", get(self.port, "/")[1])

    def test_health_ok(self) -> None:
        status, body = get(self.port, "/health")
        self.assertEqual((status, json.loads(body)), (200, {"status": "ok"}))

    def test_health_break(self) -> None:
        with mock.patch.dict(os.environ, {"BREAK": "true"}):
            self.assertEqual(get(self.port, "/health")[0], 500)

    def test_version(self) -> None:
        status, body = get(self.port, "/version")
        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(body), {"env": "test", "git_sha": "abc1234", "image_digest": "n/a"}
        )

    def test_admin_with_key(self) -> None:
        status, body = get(self.port, "/admin", {"X-API-Key": KEY})
        self.assertEqual(status, 200)
        self.assertNotIn(KEY, body)

    def test_admin_without_or_wrong_key(self) -> None:
        self.assertEqual(get(self.port, "/admin")[0], 401)
        status, body = get(self.port, "/admin", {"X-API-Key": "wrong"})
        self.assertEqual(status, 401)
        self.assertNotIn(KEY, body)

    def test_admin_unset_or_empty_key_never_matches(self) -> None:
        with mock.patch.dict(os.environ, {"APP_API_KEY": ""}):
            self.assertEqual(get(self.port, "/admin", {"X-API-Key": ""})[0], 401)
        with mock.patch.dict(os.environ):
            del os.environ["APP_API_KEY"]
            self.assertEqual(get(self.port, "/admin", {"X-API-Key": ""})[0], 401)

    def test_unknown_path(self) -> None:
        self.assertEqual(get(self.port, "/nope")[0], 404)

    def test_version_digest_from_env(self) -> None:
        with mock.patch.dict(os.environ, {"IMAGE_DIGEST": DIGEST}):
            for path in ("/", "/version"):
                self.assertIn(DIGEST, get(self.port, path)[1])
            self.assertEqual(json.loads(get(self.port, "/version")[1])["image_digest"], DIGEST)

    def test_invalid_digest_is_na(self) -> None:
        uri = "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@" + DIGEST
        for bad in (uri, "sha256:deadbeef", DIGEST.upper(), DIGEST + "\n", "<b>"):
            with mock.patch.dict(os.environ, {"IMAGE_DIGEST": bad}):
                self.assertEqual(board.image_digest(), "n/a")
                self.assertNotIn("123456789012", get(self.port, "/version")[1])


class ApiKeyTest(unittest.TestCase):
    env = {
        "APP_ENV": "dev",
        "APP_API_KEY_SECRET_ARN": ARN,
        "AWS_ACCESS_KEY_ID": "AKIDTEST",
        "AWS_SECRET_ACCESS_KEY": "fake-secret-key",
        "AWS_SESSION_TOKEN": "fake-session-token",
        "AWS_REGION": "ap-southeast-1",
    }

    def setUp(self) -> None:
        patcher = mock.patch.dict(os.environ, self.env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        board._secret_cache.clear()
        self.addCleanup(board._secret_cache.clear)

    def use(self, fake: FakeSecretsManager) -> FakeSecretsManager:
        patcher = mock.patch.object(board, "_SECRETS_ENDPOINT", fake.url)
        patcher.start()
        self.addCleanup(patcher.stop)
        return fake.start(self)

    def test_local_key_wins_without_network(self) -> None:
        with (
            mock.patch.dict(os.environ, {"APP_API_KEY": KEY}),
            mock.patch("aws_sigv4.get_secret_value", side_effect=AssertionError("network")),
        ):
            self.assertEqual(board.api_key(), KEY)

    def test_no_key_and_no_arn_is_empty(self) -> None:
        with mock.patch.dict(os.environ, {"APP_API_KEY_SECRET_ARN": ""}):
            self.assertEqual(board.api_key(), "")

    def test_secret_read_once_and_cached(self) -> None:
        fake = self.use(FakeSecretsManager())
        self.assertEqual(board.api_key(), "s3cret")
        self.assertEqual(board.api_key(), "s3cret")
        self.assertEqual(len(fake.requests), 1)
        self.assertEqual(json.loads(fake.requests[0][1]), {"SecretId": ARN})

    def test_failed_read_is_empty_logged_without_secret_and_retried_later(self) -> None:
        fake = self.use(FakeSecretsManager(status=400, payload={"__type": "AccessDenied"}))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(board.api_key(), "")
            self.assertEqual(board.api_key(), "")
        self.assertEqual(out.getvalue(), "secret read failed: HTTPError\n")
        self.assertEqual(len(fake.requests), 1)
        fake.status, fake.payload = 200, {"SecretString": "s3cret"}
        later = time.monotonic() + board.SECRET_RETRY_SECONDS + 1
        with mock.patch("time.monotonic", return_value=later):
            self.assertEqual(board.api_key(), "s3cret")
        self.assertEqual(len(fake.requests), 2)

    def test_admin_and_index_with_fetched_key(self) -> None:
        self.use(FakeSecretsManager())
        server = board.make_server(0)
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        status, body = get(port, "/admin", {"X-API-Key": "s3cret"})
        self.assertEqual(status, 200)
        self.assertNotIn("s3cret", body)
        self.assertEqual(get(port, "/admin", {"X-API-Key": "wrong"})[0], 401)
        page = get(port, "/")[1]
        self.assertIn("secret_loaded: yes", page)
        self.assertNotIn("s3cret", page)
        self.assertNotIn(ARN, page)


class SigtermTest(unittest.TestCase):
    def test_sigterm_stops_server(self) -> None:
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        src = os.path.join(os.path.dirname(__file__), "..", "src", "board.py")
        env = {**os.environ, "PORT": str(port), "PYTHONUNBUFFERED": "1"}
        proc = subprocess.Popen([sys.executable, "-B", src], env=env)  # noqa: S603
        self.addCleanup(proc.kill)
        deadline = time.monotonic() + 10
        while get_status(port) != 200:
            self.assertLess(time.monotonic(), deadline, "server did not start")
            time.sleep(0.1)
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=5), 0)


def get_status(port: int) -> int:
    try:
        return get(port, "/health")[0]
    except OSError:
        return 0


if __name__ == "__main__":
    unittest.main()
