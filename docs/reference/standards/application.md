# Application standards

The Python app (`app/`), its container image and how it runs on Fargate. Part of the [standards index](README.md); anything a linter enforces is not repeated.

## Python (`app/`)

### Scope

- Standard library only, no runtime dependencies (ADR D4). Dev tools (ruff, mypy) run through
  pre-commit or `uvx` and never land in the image.
- Keep the app tiny: one module, about 100 lines ([requirements, demo app](../../requirements.md#demo-app)). The app is not the point of the
  lab; the pipeline is.

### Naming, imports

- Module-internal helpers get a leading underscore. Names without one are the public surface.
- Absolute imports only, no wildcard imports. Ruff's `I` and `N` rules handle order and case.

### Type hints

- Every function signature is fully typed; mypy runs in strict mode.
- Use `X | None`, `list[str]`, `dict[str, int]`. No `Optional`, `List`, `Dict`, and no
  `from __future__ import annotations` (Python 3.13). Ruff's `UP` rules flag the old forms.
- `Any` only where the runtime type is genuinely unknown (for example `*args` passed through to a
  base class).

### Docstrings, comments

- A docstring or comment earns its place when it records a contract, invariant or reason that the
  code cannot show. Do not describe what the next line does.
- Every `# noqa` carries the reason on the same line or the line above.

### Secrets and logging

- Never print, log or return the value of `APP_API_KEY` or any secret. Log method, path and
  status only, never headers.
- Compare secrets with `hmac.compare_digest`. An empty or unset expected secret never matches.
- Escape every value placed in HTML (`html.escape`).

### Error handling

- Catch specific exceptions. A broad `except Exception` is acceptable only for an optional,
  best-effort lookup that has a safe fallback (for example the ECS metadata digest returning
  `n/a`).
- When re-raising a different type, chain it: `raise NewError(...) from e`.

### Testing

- stdlib `unittest`; test files are named `test_<module>.py`.
- Every endpoint and branch of behavior the requirements name has a test (`BREAK=true`, 401 cases,
  the secret never appearing in a response).
- Tests never call real external services. Mock `urllib.request.urlopen` for ECS metadata.
- No tests that only assert something exists, and no trivial tests the type checker already
  covers. Test edge cases, not a coverage percentage.

## Dockerfile (`app/Dockerfile`)

- Base images pinned by digest (`python:3.13-slim@sha256:...`), tag kept for readability (NFR-3).
- The base is one literal `FROM <registry>/python:<tag>@sha256:<digest> AS base`, and every other
  stage starts `FROM base`. No `ARG` in `FROM`: Dependabot cannot read it. The registry fallback
  swaps the `base` stage with `--build-context` (ADR 0007 S21).
- The Compose file is `app/compose.yaml` (the Docker default name).
- Multi-stage: tests run in a build stage; the runtime stage copies only `src/`.
- Run as a numeric non-root user (`USER 10001:10001`).
- `HEALTHCHECK` hits `/health` with Python, no extra packages.
- No secrets in `ARG` or `ENV`. `GIT_SHA` is the only build arg. Secrets arrive at runtime
  (compose `env_file` locally, ECS `secrets[]` in AWS).
- `.dockerignore` keeps `.env*` (except `.env.example`), `.git` and caches out of the context.
- No `# syntax=` line unless a feature needs it; if it does, pin it by digest.

## App runtime (Fargate)

- The app runs as UID 10001 with a read-only root filesystem and a root-owned `/tmp`: it must never write to
  disk. `make smoke` runs the image that way.
- Handle SIGTERM and exit 0 quickly, so rolling deploys and `docker compose down` are fast.
- Never show the ECS metadata `Image` field (it holds the registry host with the account ID); `ImageID` only.
