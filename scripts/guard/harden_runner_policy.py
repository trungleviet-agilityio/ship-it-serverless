"""harden-runner policy for GitHub workflow files (ADR 0007 S45, NFR-4).

Jobs that hold AWS credentials (`id-token: write`) must run harden-runner in block mode with
telemetry off and an exact allowlist, so an exfiltration path needs an allowed host and the
account-bearing hostnames never reach a third-party insights page. Every other job must say
`egress-policy: audit` out loud, so a new job cannot ship with the action's silent default (block)
or with no hardening.

Rules, per job:
  1. the first step is step-security/harden-runner, with no `if:` and no `continue-on-error:`;
  2. a job with `id-token: write` has `egress-policy: block`, `disable-telemetry: true` and
     `disable-sudo-and-containers: true` (except the jobs in NEEDS_CONTAINERS), and no
     `container:` or `services:`;
  3. any other job has `egress-policy: audit`;
  4. every allowed endpoint is `host:port` and holds no 12-digit literal (an account ID);
  5. in a credentialed job an endpoint holds no `*`, and the only expressions are the ones in
     ALLOWED_EXPRESSIONS (account hosts come from the secret, never from a literal), plus
     `secrets.AWS_ACCOUNT_ID_DEV` in the jobs of SOURCE_REGISTRY_JOBS only (the promotion source
     registry host, ADR 0008 P8);
  6. `env.ENV` in a credentialed job names the environment, so ENV must be a literal, or exactly
     `inputs.env` (optionally `|| '<literal>'`) where `env` is a `choice` input of
     workflow_dispatch (a workflow_call input in a reusable-*.yml file). A branch name, free text
     or any other expression could steer the allowlist or the state bucket host;
  7. in any other job (audit) an endpoint may use `vars.X` and `env.X` only: no `secrets` in any
     form (`secrets.`, `secrets[`, `toJSON(secrets)`), no `env[...]`, `format(...)` or other
     function, and no `env.X` whose value is built from a secret, directly or through other env
     values: an env value is clean only as a literal or from `vars.X` and clean `env.X`, so
     `env[...]`, `toJSON(env)`, `github.*`, an `env:` expression and an undefined `env.X` all
     fail closed; `secrets` matches in any letter case (ADR 0007 N1, ADR 0008 P8);
  8. a job with `uses:` calls a reusable workflow. It has no steps, so it is checked through its
     callee (the reusable-*.yml file is checked like any workflow). It must call
     ./.github/workflows/reusable-*.yml and must not pass `secrets: inherit`;
  9. a reusable-*.yml file sets a top-level `permissions: {}` and every job sets its own
     `permissions:`, so what a job can do is read in the job; a job is credentialed when its own
     permissions grant `id-token`.

Usage: python -I scripts/guard/harden_runner_policy.py <workflow file>...
Prints one violation per line on stdout, with paths relative to the working directory.
Exit codes: 0 all files pass, 1 violations, 2 usage error.
Run through scripts/guard/harden-runner.sh, which picks the interpreter and lists the files.
"""

import os
import re
import sys
from typing import Any

# `python -I` leaves the script directory off sys.path; the helper module sits next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workflow_yaml import dispatch_options, run, trigger_input  # noqa: E402  (import after the path setup above)

ACTION = "step-security/harden-runner@"
# One endpoint is a run of non-space characters; `${{ ... }}` may hold spaces and stays whole.
ENDPOINT = re.compile(r"(?:\$\{\{.*?\}\}|\S)+")
# DOTALL: an expression may span lines (a YAML block scalar) and must still be seen.
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}", re.DOTALL)
PORT = re.compile(r":[0-9]{1,5}$")
ACCOUNT_ID = re.compile(r"(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])")
# The account ID is the environment secret AWS_ACCOUNT_ID (a reusable workflow gets that name too).
ALLOWED_EXPRESSIONS = ("vars.AWS_REGION", "secrets.AWS_ACCOUNT_ID", "env.ENV")
# Context names are case-insensitive: `SECRETS.X` and `Secrets[...]` read a secret too.
SECRETS_REF = re.compile(r"\bsecrets\b", re.IGNORECASE)
ENV_REF = re.compile(r"^env\.([A-Za-z_][A-Za-z0-9_]*)$", re.IGNORECASE)
VARS_REF = re.compile(r"^vars\.[A-Za-z_][A-Za-z0-9_]*$")
# The only forms of the ENV value that follow an input: `${{ inputs.env }}`, or with a literal
# fallback.
ENV_FROM_INPUT = re.compile(r"^\$\{\{\s*inputs\.env(?:\s*\|\|\s*'([^']*)')?\s*\}\}$")
ENV_NAME = re.compile(r"^[a-z][a-z0-9]{1,7}$")  # lib.sh ENV_NAME_RE
REUSABLE_CALL = re.compile(r"^\./\.github/workflows/reusable-[A-Za-z0-9._-]+\.ya?ml$")
# The one credentialed job that needs Docker (docker load and docker push), so it cannot disable
# containers. The residual risk is recorded in ADR 0007. Keyed by (workflow file name, job id).
NEEDS_CONTAINERS = (("app-deploy.yml", "deploy"),)
# The one credentialed job that reads a second account: app-promote pulls from the dev registry,
# whose host holds the dev account ID (ADR 0008 P8, P9). Keyed by (workflow file name, job id).
SOURCE_REGISTRY_JOBS = (("app-promote.yml", "promote"),)
SOURCE_REGISTRY_EXPRESSION = "secrets.AWS_ACCOUNT_ID_DEV"


def _has_id_token(permissions: Any) -> bool:
    if permissions == "write-all":
        return True
    return isinstance(permissions, dict) and permissions.get("id-token") == "write"


OPAQUE_ENV = "*opaque*"  # key of the merged env when some `env:` is an expression, not a mapping
CLEAN_EXPRESSION = re.compile(r"^(vars|env)\.([A-Za-z_][A-Za-z0-9_]*)$", re.IGNORECASE)


def _env_name_is_clean(name: str, env: dict[str, Any], seen: frozenset[str] = frozenset()) -> bool:
    """Whether env value `name` is provably free of secrets (fail closed).

    Clean means a literal, or built only from `vars.X` and other clean `env.X`. Anything else
    taints: any secrets form, `env[...]`, `toJSON(env)`, `github.*`, `steps.*`, `needs.*` or other
    expressions, an `env:` that is an expression instead of a mapping, and a name no literal
    mapping defines.
    Env names are case-insensitive in expressions: with keys that differ only in case, the name is
    clean only if every variant is. A cycle adds no taint of its own.
    """
    key = name.lower()
    if OPAQUE_ENV in env:
        return False
    if key in seen:
        return True
    variants = [v for k, v in env.items() if str(k).lower() == key]
    if not variants:
        return False
    for value in variants:
        text = str(value)
        # The raw text is checked too: a mention of secrets or the token anywhere, or a `${{`
        # that no complete expression consumed (an unclosed one), is never trusted as a literal.
        if SECRETS_REF.search(text) or "github.token" in text.lower():
            return False
        if "${{" in EXPRESSION.sub("", text):
            return False
        for expression in EXPRESSION.findall(text):
            ref = CLEAN_EXPRESSION.match(expression)
            if not ref:
                return False
            if ref.group(1).lower() == "env" and not _env_name_is_clean(
                ref.group(2), env, seen | {key}
            ):
                return False
    return True


def _endpoint_problems(
    endpoint: str, credentialed: bool, env: dict[str, Any], allowed: tuple[str, ...]
) -> list[str]:
    problems: list[str] = []
    expressions = EXPRESSION.findall(endpoint)
    literal = EXPRESSION.sub("", endpoint)
    if not PORT.search(endpoint):
        problems.append(f"endpoint '{endpoint}' has no :port")
    if ACCOUNT_ID.search(literal):
        problems.append("an endpoint holds a 12-digit literal (build it from a secret expression)")
    if credentialed:
        if "*" in literal:
            problems.append(f"endpoint '{endpoint}' holds a wildcard (list exact hosts)")
        problems.extend(
            f"endpoint '{endpoint}' uses the expression '{e}' (allowed: {', '.join(allowed)})"
            for e in expressions
            if e not in allowed
        )
    else:
        for e in expressions:
            ref = ENV_REF.match(e)
            if SECRETS_REF.search(e):
                problems.append(
                    f"endpoint '{endpoint}' reads a secret in a job without credentials"
                )
            elif ref and not _env_name_is_clean(ref.group(1), env):
                problems.append(
                    f"endpoint '{endpoint}' uses env {ref.group(1)}, which is built from a secret "
                    "or from a source that is not proven clean, in a job without credentials"
                )
            elif not ref and not VARS_REF.match(e):
                problems.append(
                    f"endpoint '{endpoint}' uses the expression '{e}' "
                    "(a job without credentials may use vars.X and env.X only)"
                )
    return problems


def _env_value_problem(value: Any, document: Any, reusable: bool) -> str | None:
    """Why `env.ENV` may not name the environment in an allowlist, or None when it may."""
    text = str(value) if value is not None else ""
    if not text:
        return "ENV is not set at the workflow, job or harden-runner step level"
    if "${{" not in text:
        return None if ENV_NAME.match(text) else f"ENV '{text}' is not a valid environment name"
    match = ENV_FROM_INPUT.match(text)
    if not match:
        return f"ENV is '{text}'; it must be a literal or inputs.env (optionally || 'literal')"
    fallback = match.group(1)
    if fallback is not None and not ENV_NAME.match(fallback):
        return f"the ENV fallback '{fallback}' is not a valid environment name"
    if reusable:
        if trigger_input(document, "workflow_call", "env") is None:
            return "ENV follows inputs.env, but the workflow has no workflow_call input env"
        return None
    definition = trigger_input(document, "workflow_dispatch", "env")
    if not definition or definition.get("type") != "choice":
        return "ENV follows inputs.env, so the workflow_dispatch input env must be type: choice"
    if fallback is not None and fallback not in dispatch_options(document, "env"):
        return f"the ENV fallback '{fallback}' is not one of the options of the env input"
    return None


def _step_problems(
    step: Any,
    credentialed: bool,
    needs_containers: bool,
    env: dict[str, Any],
    env_problem: str | None,
    allowed: tuple[str, ...] = ALLOWED_EXPRESSIONS,
) -> list[str]:
    uses = step.get("uses") if isinstance(step, dict) else None
    if not isinstance(uses, str) or not uses.startswith(ACTION):
        return ["the first step is not step-security/harden-runner"]
    problems = [
        f"harden-runner must not set `{k}:`" for k in ("if", "continue-on-error") if k in step
    ]
    with_ = step.get("with")
    with_ = with_ if isinstance(with_, dict) else {}
    policy = with_.get("egress-policy")
    if credentialed:
        required = ["disable-telemetry"]
        if not needs_containers:
            required.append("disable-sudo-and-containers")
        if policy != "block":
            problems.append("has id-token: write, so egress-policy must be block")
        problems.extend(
            f"has id-token: write, so {key} must be true"
            for key in required
            if with_.get(key) not in (True, "true")
        )
    elif policy != "audit":
        problems.append("has no id-token: write, so egress-policy must be audit (written out)")
    endpoints = with_.get("allowed-endpoints")
    found = ENDPOINT.findall(endpoints if isinstance(endpoints, str) else "")
    for endpoint in found:
        problems.extend(_endpoint_problems(endpoint, credentialed, env, allowed))
    uses_env = any("env.ENV" in EXPRESSION.findall(e) for e in found)
    if credentialed and uses_env and env_problem:
        problems.append(f"an endpoint uses env.ENV, but {env_problem}")
    return problems


def _call_problems(job: dict[str, Any]) -> list[str]:
    problems: list[str] = []
    if not REUSABLE_CALL.match(str(job["uses"])):
        problems.append("a reusable call must target ./.github/workflows/reusable-*.yml")
    if job.get("secrets") == "inherit":
        problems.append("a reusable call must pass its secrets by name, never `secrets: inherit`")
    return problems


def _merged_env(document: Any, job: dict[str, Any], step: Any) -> dict[str, Any]:
    """Workflow, job and first-step `env:` values, the narrowest scope winning.

    An `env:` that is not a mapping (an expression) cannot be read, so the result is marked opaque.
    """
    merged: dict[str, Any] = {}
    for scope in (document, job, step):
        env = scope.get("env") if isinstance(scope, dict) else None
        if isinstance(env, dict):
            merged.update(env)
        elif env is not None:
            merged[OPAQUE_ENV] = True
    return merged


def check(shown: str, document: Any) -> list[str]:
    """Violations of one parsed workflow, as `<file>: job '<id>': <message>` lines."""
    jobs = document.get("jobs") if isinstance(document, dict) else None
    if not isinstance(jobs, dict):
        return [f"{shown}: no jobs mapping"]
    reusable = os.path.basename(shown).startswith("reusable-")
    workflow_permissions = document.get("permissions")
    problems: list[str] = []
    if reusable and workflow_permissions != {}:
        problems.append(
            f"{shown}: a reusable workflow must set top-level `permissions: {{}}` "
            "(each job then states its own)"
        )
    for job_id, job in jobs.items():
        job = job if isinstance(job, dict) else {}
        if "uses" in job:
            problems.extend(f"{shown}: job '{job_id}': {m}" for m in _call_problems(job))
            continue
        messages: list[str] = []
        if reusable and "permissions" not in job:
            messages.append("a job of a reusable workflow must set its own `permissions:`")
        # A job without its own `permissions:` inherits the workflow's.
        credentialed = _has_id_token(job.get("permissions", workflow_permissions))
        steps = job.get("steps")
        first = steps[0] if isinstance(steps, list) and steps else None
        needs_containers = (os.path.basename(shown), job_id) in NEEDS_CONTAINERS
        merged = _merged_env(document, job, first)
        env_problem = _env_value_problem(merged.get("ENV"), document, reusable)
        allowed = ALLOWED_EXPRESSIONS
        if (os.path.basename(shown), job_id) in SOURCE_REGISTRY_JOBS:
            allowed = (*ALLOWED_EXPRESSIONS, SOURCE_REGISTRY_EXPRESSION)
        messages += _step_problems(
            first, credentialed, needs_containers, merged, env_problem, allowed
        )
        if credentialed:
            messages += [
                f"has id-token: write, so `{k}:` is not allowed"
                for k in ("container", "services")
                if k in job
            ]
        problems.extend(f"{shown}: job '{job_id}': {m}" for m in messages)
    return problems


if __name__ == "__main__":
    sys.exit(run("harden_runner_policy.py", check, sys.argv[1:]))
