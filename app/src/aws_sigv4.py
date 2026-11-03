"""AWS Signature Version 4 and one Secrets Manager call, standard library only (ADR 0012 L5)."""

import datetime
import hashlib
import hmac
import json
import urllib.parse
import urllib.request
from typing import NamedTuple

ALGORITHM = "AWS4-HMAC-SHA256"


class Credentials(NamedTuple):
    access_key: str
    secret_key: str
    session_token: str = ""


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def _quote(value: str) -> str:
    return urllib.parse.quote(value, safe="-_.~")


def canonical_request(
    method: str, url: str, headers: dict[str, str], body: bytes
) -> tuple[str, str]:
    """Return (canonical request, signed headers). Header names must already be lower case."""
    parts = urllib.parse.urlsplit(url)
    path = urllib.parse.quote(parts.path or "/", safe="/-_.~")
    pairs = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    query = "&".join(f"{k}={v}" for k, v in sorted((_quote(k), _quote(v)) for k, v in pairs))
    names = sorted(headers)
    block = "".join(f"{n}:{' '.join(headers[n].split())}\n" for n in names)
    signed = ";".join(names)
    return "\n".join([method, path, query, block, signed, _sha256(body)]), signed


def signing_key(secret_key: str, date: str, region: str, service: str) -> bytes:
    key = _hmac(("AWS4" + secret_key).encode(), date)
    for part in (region, service, "aws4_request"):
        key = _hmac(key, part)
    return key


def string_to_sign(amz_date: str, scope: str, canonical_hash: str) -> str:
    return "\n".join([ALGORITHM, amz_date, scope, canonical_hash])


def sign(
    method: str,
    url: str,
    region: str,
    service: str,
    headers: dict[str, str],
    body: bytes,
    access_key: str,
    secret_key: str,
    session_token: str = "",
    amz_date: str | None = None,
) -> dict[str, str]:
    """Return the headers to send (lower-case names), Authorization included."""
    amz_date = amz_date or datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    out = {k.lower(): v for k, v in headers.items()}
    out.setdefault("host", urllib.parse.urlsplit(url).netloc)
    out["x-amz-date"] = amz_date
    if session_token:
        out["x-amz-security-token"] = session_token
    canonical, signed = canonical_request(method, url, out, body)
    scope = f"{amz_date[:8]}/{region}/{service}/aws4_request"
    to_sign = string_to_sign(amz_date, scope, _sha256(canonical.encode()))
    key = signing_key(secret_key, amz_date[:8], region, service)
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    out["authorization"] = (
        f"{ALGORITHM} Credential={access_key}/{scope}, "
        f"SignedHeaders={signed}, Signature={signature}"
    )
    return out


def get_secret_value(
    secret_id: str, region: str, creds: Credentials, endpoint: str | None = None, timeout: float = 2
) -> str:
    """Return SecretString. `endpoint` is for tests only: https, or http on 127.0.0.1."""
    url = endpoint or f"https://secretsmanager.{region}.amazonaws.com/"
    parts = urllib.parse.urlsplit(url)
    if not (parts.scheme == "https" or (parts.scheme == "http" and parts.hostname == "127.0.0.1")):
        raise ValueError("endpoint must be https (or http on 127.0.0.1 in tests)")
    body = json.dumps({"SecretId": secret_id}).encode()
    headers = sign(
        "POST",
        url,
        region,
        "secretsmanager",
        {
            "content-type": "application/x-amz-json-1.1",
            "x-amz-target": "secretsmanager.GetSecretValue",
        },
        body,
        creds.access_key,
        creds.secret_key,
        creds.session_token,
    )
    # The scheme is checked above: https, or http to 127.0.0.1 only.
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")  # noqa: S310
    with urllib.request.urlopen(request, timeout=timeout) as resp:  # noqa: S310
        value = json.loads(resp.read()).get("SecretString")
    if not isinstance(value, str):
        raise ValueError("response has no SecretString")
    return value
