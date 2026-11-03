"""Tests for the stdlib SigV4 signer and the Secrets Manager call. Run from app/."""

import hashlib
import json
import os
import re
import sys
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import aws_sigv4  # noqa: E402

# AWS published example, IAM docs "Create a signed AWS API request" (ListUsers).
IAM_URL = "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08"
IAM_HEADERS = {
    "content-type": "application/x-www-form-urlencoded; charset=utf-8",
    "host": "iam.amazonaws.com",
    "x-amz-date": "20150830T123600Z",
}
IAM_SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
AUTH_RE = re.compile(
    r"AWS4-HMAC-SHA256 Credential=AKIDTEST/\d{8}/ap-southeast-1/secretsmanager/aws4_request, "
    r"SignedHeaders=[a-z0-9;-]+, Signature=[0-9a-f]{64}"
)
CREDS = aws_sigv4.Credentials("AKIDTEST", "fake-secret-key", "fake-session-token")


class FakeSecretsManager:
    """Local Secrets Manager stand-in on 127.0.0.1; records each request it receives."""

    def __init__(self, status: int = 200, payload: dict[str, Any] | None = None) -> None:
        self.status = status
        self.payload = payload if payload is not None else {"SecretString": "s3cret"}
        self.requests: list[tuple[dict[str, str], bytes]] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                fake.requests.append(({k.lower(): v for k, v in self.headers.items()}, body))
                data = json.dumps(fake.payload).encode()
                self.send_response(fake.status)
                self.send_header("Content-Type", "application/x-amz-json-1.1")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, format: str, *args: Any) -> None:
                return None

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/"

    def start(self, case: unittest.TestCase) -> "FakeSecretsManager":
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        case.addCleanup(self.server.server_close)
        case.addCleanup(self.server.shutdown)
        return self


class SignerTest(unittest.TestCase):
    def test_published_canonical_request_hash(self) -> None:
        canonical, signed = aws_sigv4.canonical_request("GET", IAM_URL, IAM_HEADERS, b"")
        self.assertEqual(signed, "content-type;host;x-amz-date")
        self.assertEqual(
            hashlib.sha256(canonical.encode()).hexdigest(),
            "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59",
        )

    def test_published_signing_key(self) -> None:
        key = aws_sigv4.signing_key(IAM_SECRET, "20150830", "us-east-1", "iam")
        self.assertEqual(
            key.hex(), "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
        )

    def test_published_signature(self) -> None:
        headers = aws_sigv4.sign(
            "GET",
            IAM_URL,
            "us-east-1",
            "iam",
            IAM_HEADERS,
            b"",
            "AKIDEXAMPLE",
            IAM_SECRET,
            amz_date="20150830T123600Z",
        )
        self.assertEqual(
            headers["authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, "
            "SignedHeaders=content-type;host;x-amz-date, "
            "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7",
        )
        self.assertNotIn("x-amz-security-token", headers)

    def test_session_token_is_sent_and_signed(self) -> None:
        headers = aws_sigv4.sign(
            "GET", IAM_URL, "us-east-1", "iam", {}, b"", "AKID", "k", session_token="tok"
        )
        self.assertEqual(headers["x-amz-security-token"], "tok")
        self.assertEqual(headers["host"], "iam.amazonaws.com")
        self.assertIn(
            "SignedHeaders=host;x-amz-date;x-amz-security-token,", headers["authorization"]
        )


class GetSecretValueTest(unittest.TestCase):
    def setUp(self) -> None:
        # No proxy variables: the fake server is on 127.0.0.1.
        patcher = mock.patch.dict(os.environ, {}, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_signed_request_returns_secret_string(self) -> None:
        fake = FakeSecretsManager().start(self)
        arn = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:sis-dev-app-key-AbCdEf"
        value = aws_sigv4.get_secret_value(arn, "ap-southeast-1", CREDS, endpoint=fake.url)
        self.assertEqual(value, "s3cret")
        self.assertEqual(len(fake.requests), 1)
        headers, body = fake.requests[0]
        self.assertEqual(headers["x-amz-target"], "secretsmanager.GetSecretValue")
        self.assertEqual(headers["content-type"], "application/x-amz-json-1.1")
        self.assertEqual(headers["x-amz-security-token"], "fake-session-token")
        self.assertRegex(headers["authorization"], AUTH_RE)
        self.assertIn("x-amz-security-token", headers["authorization"])
        self.assertEqual(json.loads(body), {"SecretId": arn})

    def test_http_error_raises(self) -> None:
        fake = FakeSecretsManager(status=400, payload={"__type": "AccessDeniedException"})
        fake.start(self)
        with self.assertRaises(urllib.error.HTTPError):
            aws_sigv4.get_secret_value("arn", "ap-southeast-1", CREDS, endpoint=fake.url)

    def test_missing_secret_string_raises(self) -> None:
        fake = FakeSecretsManager(payload={"SecretBinary": "AAAA"}).start(self)
        with self.assertRaises(ValueError):
            aws_sigv4.get_secret_value("arn", "ap-southeast-1", CREDS, endpoint=fake.url)

    def test_plain_http_refused_off_loopback(self) -> None:
        with self.assertRaises(ValueError):
            aws_sigv4.get_secret_value("arn", "ap-southeast-1", CREDS, endpoint="http://x/")


if __name__ == "__main__":
    unittest.main()
