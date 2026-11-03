---
paths:
  - "app/**"
---

# App

Read `docs/reference/standards/application.md` before editing. Lab-specific points it builds on:

- Python 3.13, standard library only (D4). The Secrets Manager read is stdlib SigV4 (`app/src/aws_sigv4.py`).
- Contract with the platform: one port (`PORT`, 8080), `/health` as the Lambda Web Adapter readiness path,
  `/version` with env, git SHA and `IMAGE_DIGEST`.
- On Lambda (`AWS_LAMBDA_FUNCTION_NAME` set) the key comes only from the secret; a plain `APP_API_KEY` is
  ignored (ADR 0012 L5). Never log the key.
- The image must run unchanged in compose, CI and Lambda: check with `make verify`.
