"""Environment parity guard (ADR 0008, P3, R26).

Every environment has its own thin Terraform root under infra/terraform/envs/<env>/, and the
roots are copies of each other. This keeps the copies honest. With E the set of directories under
envs/ (dot-directories ignored):

  1. every root holds the same files as envs/dev/ (local state, plans, .terraform/ and
     *.auto.tfvars are ignored);
  2. every file is byte-identical to envs/dev/ except terraform.tfvars, versions.tf and
     .terraform.lock.hcl (a staged provider upgrade), the `key` line of backend.tf, and the
     generated terraform-docs block of README.md (it lists the versions);
  3. backend.tf has `key = "envs/<env>/terraform.tfstate"`, and terraform.tfvars has
     `env = "<env>"`;
  4. vpc_cidr is unique across E;
  5. bootstrap/accounts/<env>.tfvars.example exists;
  6. the environment lists in the workflows hold exactly E: the choice of the terraform-iac
     dispatch input `env`, one `plan-<env>` caller job of reusable-terraform-plan.yml per env, the
     terraform-destroy choice, and the `allowed_envs` of its confirm job;
  7. a `plan-<env>` caller maps only secrets named `*_<ENV>` (upper case), so a copied caller
     cannot plan one account with the credentials of another. One exception (ADR 0008 P9): when
     terraform.tfvars sets `promotion_target_env = "<target>"`, the caller must also map
     PROMOTION_TARGET_ACCOUNT_ID, and only from secrets.AWS_ACCOUNT_ID_<TARGET>.

Usage: python -I scripts/guard/env_parity.py [repo root]   (default: the current directory)
Prints one violation per line on stdout. Exit codes: 0 holds, 1 violations, 2 usage error.
Run through scripts/guard/env-parity.sh, which picks the interpreter.
"""

import os
import re
import sys
from pathlib import Path
from typing import Any

# `python -I` leaves the script directory off sys.path; the helper module sits next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workflow_yaml import dispatch_options, read_workflow  # noqa: E402  (import after the path setup above)

REFERENCE = "dev"
MAY_DIFFER = ("terraform.tfvars", "versions.tf", ".terraform.lock.hcl")
IGNORED_DIRS = (".terraform",)
IGNORED_FILE = re.compile(r"(\.auto\.tfvars|\.tfstate(\..*)?|\.tfplan|^tfplan)$")
KEY_VALUE = re.compile(r'^\s*key\s*=\s*"([^"]*)"\s*$', re.MULTILINE)
BACKEND_KEY = re.compile(r'^(\s*key\s*=\s*)"[^"]*"\s*$', re.MULTILINE)
DOCS_BLOCK = re.compile(r"<!-- BEGIN_TF_DOCS -->.*<!-- END_TF_DOCS -->", re.DOTALL)
ENV_LINE = re.compile(r'^env\s*=\s*"([^"]*)"\s*(#.*)?$', re.MULTILINE)
PROMOTION_LINE = re.compile(r'^promotion_target_env\s*=\s*"([^"]*)"\s*(#.*)?$', re.MULTILINE)
PROMOTION_KEY = "PROMOTION_TARGET_ACCOUNT_ID"
CIDR_LINE = re.compile(r'^vpc_cidr\s*=\s*"([^"]*)"\s*(#.*)?$', re.MULTILINE)
ALLOWED_ENVS = re.compile(r'^\s*allowed_envs="([^"]*)"\s*$', re.MULTILINE)
SECRET_REF = re.compile(r"^\$\{\{\s*secrets\.([A-Za-z0-9_]+)\s*\}\}$")
REUSABLE_PLAN = "./.github/workflows/reusable-terraform-plan.yml"
IAC = "terraform-iac.yml"
DESTROY = "terraform-destroy.yml"


def _files(root: Path) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_DIRS]
        for name in filenames:
            if not IGNORED_FILE.search(name):
                path = Path(dirpath) / name
                found[path.relative_to(root).as_posix()] = path
    return found


def _normalize(rel: str, text: str) -> str:
    if rel == "backend.tf":
        return BACKEND_KEY.sub(r'\1"<key>"', text)
    if rel == "README.md":
        return DOCS_BLOCK.sub("<tf-docs>", text)
    return text


def _single(pattern: re.Pattern[str], text: str) -> str | None:
    found = pattern.findall(text)
    return found[0][0] if len(found) == 1 else None


def _env_line_problem(name: str, root: Path) -> str | None:
    """The problem with the `env = "<name>"` line of root/terraform.tfvars, or None.

    A missing file is not a problem here: the missing file is reported on its own.
    """
    tfvars = root / "terraform.tfvars"
    if not tfvars.is_file():
        return None
    found = _single(ENV_LINE, tfvars.read_text(encoding="utf-8"))
    if found == name:
        return None
    return (
        f"env '{name}': terraform.tfvars must have exactly one line "
        f'env = "{name}" (found {found!r})'
    )


def _root_problems(name: str, root: Path, reference: dict[str, Path]) -> list[str]:
    files = _files(root)
    problems = [
        f"env '{name}': missing {rel} (present in envs/{REFERENCE})"
        for rel in sorted(set(reference) - set(files))
    ]
    problems += [
        f"env '{name}': extra file {rel} (not in envs/{REFERENCE})"
        for rel in sorted(set(files) - set(reference))
    ]
    for rel in sorted(set(files) & set(reference)):
        if rel in MAY_DIFFER:
            continue
        mine = _normalize(rel, files[rel].read_text(encoding="utf-8"))
        theirs = _normalize(rel, reference[rel].read_text(encoding="utf-8"))
        if mine != theirs:
            allowed = ", ".join(MAY_DIFFER)
            problems.append(
                f"env '{name}': {rel} differs from envs/{REFERENCE} "
                f"(only {allowed}, the backend key and the docs block may)"
            )
    backend = files.get("backend.tf")
    if backend is not None:
        keys = KEY_VALUE.findall(backend.read_text(encoding="utf-8"))
        if len(keys) != 1:
            problems.append(f"env '{name}': backend.tf must have exactly one key line")
        elif keys[0] != f"envs/{name}/terraform.tfstate":
            problems.append(
                f"env '{name}': backend.tf key must be envs/{name}/terraform.tfstate, "
                f"found {keys[0]}"
            )
    problem = _env_line_problem(name, root)
    if problem:
        problems.append(problem)
    return problems


def _cidr(root: Path) -> str | None:
    path = root / "terraform.tfvars"
    return _single(CIDR_LINE, path.read_text(encoding="utf-8")) if path.is_file() else None


def _list_problems(label: str, found: list[str], envs: list[str]) -> list[str]:
    problems = [f"env '{e}': missing from {label}" for e in envs if e not in found]
    problems += [
        f"{label} lists '{e}', which has no envs/{e}/ root" for e in found if e not in envs
    ]
    return problems


def _load(path: Path) -> Any:
    try:
        return read_workflow(path)
    except ValueError as e:
        raise ValueError(f"{path.name}: {e}") from e


def _choice(document: Any, label: str) -> list[str]:
    try:
        return dispatch_options(document, "env")
    except ValueError as e:
        raise ValueError(f"{label}: {e}") from e


def _promotion_target(root: Path) -> str:
    """The promotion_target_env of root/terraform.tfvars, or "" when unset (ADR 0008 P9)."""
    path = root / "terraform.tfvars"
    found = PROMOTION_LINE.findall(path.read_text(encoding="utf-8")) if path.is_file() else []
    return found[0][0] if len(found) == 1 else ""


def _secret_problems(job_id: str, env: str, job: dict[str, Any], target: str) -> list[str]:
    """Every secret a plan caller maps is the repository secret of its own environment.

    The one exception is the promotion target account, mapped from AWS_ACCOUNT_ID_<TARGET>.
    """
    suffix = f"_{env.upper()}"
    mapped = job.get("secrets")
    if not isinstance(mapped, dict) or not mapped:
        return [f"{IAC}: job '{job_id}' must map its secrets by name"]
    problems = []
    if target and PROMOTION_KEY not in mapped:
        problems.append(
            f"{IAC}: job '{job_id}' must map {PROMOTION_KEY} from secrets.AWS_ACCOUNT_ID_"
            f"{target.upper()} (envs/{env} promotes to {target})"
        )
    for key, value in mapped.items():
        ref = SECRET_REF.match(str(value))
        if key == PROMOTION_KEY:
            expected = f"AWS_ACCOUNT_ID_{target.upper()}" if target else None
            if not ref or ref.group(1) != expected:
                problems.append(
                    f"{IAC}: job '{job_id}' maps {key} from {value!r}; "
                    + (
                        f"it must be secrets.{expected}"
                        if expected
                        else f"envs/{env} sets no promotion_target_env"
                    )
                )
            continue
        if not ref or not ref.group(1).endswith(suffix):
            problems.append(
                f"{IAC}: job '{job_id}' maps {key} from {value!r}; "
                f"it must be a secrets.<NAME> ending in {suffix}"
            )
    return problems


def _workflow_problems(workflows: Path, envs: list[str], targets: dict[str, str]) -> list[str]:
    problems: list[str] = []
    try:
        iac = _load(workflows / IAC)
        destroy = _load(workflows / DESTROY)
        problems += _list_problems(f"the {IAC} dispatch choice", _choice(iac, IAC), envs)
        problems += _list_problems(
            f"the {DESTROY} dispatch choice", _choice(destroy, DESTROY), envs
        )
    except ValueError as e:
        return [str(e)]
    jobs = iac.get("jobs") if isinstance(iac, dict) else None
    callers: dict[str, str] = {}
    for job_id, job in (jobs or {}).items():
        if isinstance(job, dict) and job.get("uses") == REUSABLE_PLAN:
            with_ = job.get("with") if isinstance(job.get("with"), dict) else {}
            callers[job_id] = str(with_.get("env"))
    for env in envs:
        if env not in callers.values():
            problems.append(
                f"env '{env}': no plan-{env} caller job of reusable-terraform-plan.yml in {IAC}"
            )
    for job_id, env in callers.items():
        if job_id != f"plan-{env}":
            problems.append(
                f"{IAC}: job '{job_id}' calls the plan for '{env}' and must be named plan-{env}"
            )
        if env not in envs:
            problems.append(f"{IAC}: job '{job_id}' plans '{env}', which has no envs/{env}/ root")
        problems += _secret_problems(job_id, env, jobs[job_id], targets.get(env, ""))
    confirm = (destroy.get("jobs") or {}).get("confirm") or {}
    script = "\n".join(
        str(s.get("run", "")) for s in confirm.get("steps") or [] if isinstance(s, dict)
    )
    guard = ALLOWED_ENVS.findall(script)
    if len(guard) != 1:
        problems.append(f'{DESTROY}: the confirm job must have exactly one allowed_envs="..." line')
    else:
        problems += _list_problems(f"the {DESTROY} allowed_envs", guard[0].split(), envs)
    return problems


def check(repo: Path) -> list[str]:
    envs_dir = repo / "infra/terraform/envs"
    envs = (
        sorted(p.name for p in envs_dir.iterdir() if p.is_dir() and not p.name.startswith("."))
        if envs_dir.is_dir()
        else []
    )
    if REFERENCE not in envs:
        return [f"envs/{REFERENCE} is the reference root and is missing"]
    reference = _files(envs_dir / REFERENCE)
    problems: list[str] = []
    cidrs: dict[str, list[str]] = {}
    for env in envs:
        if env != REFERENCE:
            problems += _root_problems(env, envs_dir / env, reference)
        cidr = _cidr(envs_dir / env)
        if cidr is None:
            problems.append(f"env '{env}': terraform.tfvars must have exactly one vpc_cidr line")
        else:
            cidrs.setdefault(cidr, []).append(env)
        example = repo / "infra/terraform/bootstrap/accounts" / f"{env}.tfvars.example"
        if not example.is_file():
            problems.append(
                f"env '{env}': missing infra/terraform/bootstrap/accounts/{env}.tfvars.example"
            )
    problem = _env_line_problem(REFERENCE, envs_dir / REFERENCE)
    if problem:
        problems.append(problem)
    problems += [
        f"vpc_cidr {c} is used by more than one env: {', '.join(sorted(e))}"
        for c, e in cidrs.items()
        if len(e) > 1
    ]
    targets = {env: _promotion_target(envs_dir / env) for env in envs}
    problems += _workflow_problems(repo / ".github/workflows", envs, targets)
    return problems


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        print("usage: env_parity.py [repo root]", file=sys.stderr)
        return 2
    repo = Path(argv[0]) if argv else Path.cwd()
    problems = check(repo)
    for line in problems:
        print(line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
