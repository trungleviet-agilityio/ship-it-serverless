---
name: ci-triage
description: Diagnose a failed or blocked GitHub Actions run in the ship-it-serverless lab (terraform-iac, app-deploy, terraform-destroy, oidc-smoke-test, repo-guard, Dependabot) - read the failed log, match it to a known cause, propose the smallest fix and record the lesson. Load when the user reports a red check, a failed run or an AccessDenied.
---

# CI triage

## 1. Known causes first

Read the lessons log in memory (`lessons-learned-log`) before anything else. Most failures in this repo have
happened before.

## 2. Read the failure

```bash
gh run list --repo trungleviet-agilityio/ship-it-serverless --limit 10
gh run view <run id> --repo trungleviet-agilityio/ship-it-serverless --log-failed
```

For a PR: `gh pr checks <pr> --repo trungleviet-agilityio/ship-it-serverless`. Quote only the lines you need, and
never paste a line that holds a 12-digit account ID or an ARN.

## 3. Classify

| Symptom in the log | Usual cause | Fix |
|---|---|---|
| "The role ARN secret or the account ID secret is empty or not set" | The account is not bootstrapped or the GitHub env secrets are missing (by design) | No code change: the checkpoint sets them (README, Checkpoint) |
| Preflight "function does not exist yet", or a secret with no AWSCURRENT value | Deploy ran before the apply or the secret value (by design) | No code change: re-run after the apply and the secret value |
| `publish.sh`: "version N refused: ..." or "publish refused: ..." | The published version does not carry the digest and description it must, or an env merge would change another key | Read the reason; `PublishVersion` returns an existing version when code and configuration are unchanged (ADR 0012 L6) |
| `smoke-invoke.sh` fails with `FunctionError` or the adapter never ready | Init failure: bad `AWS_LWA_*`, port, `/health`, or the secret read at cold start | Read `/aws/lambda/sls-<env>-app` for the version; reproduce with `make smoke` |
| Canary aborted, alias weights removed | A probe failed or `Errors` rose on the new version | Expected behavior; read the bake log per route and version |
| `CreateFunction` or `UpdateFunctionCode` AccessDenied on ECR | The caller lacks `ecr:BatchGetImage` / `ecr:GetDownloadUrlForLayer`, or the repo policy `aws:sourceArn` does not match | Fix the bootstrap policy; an admin re-applies bootstrap |
| `AccessDenied` on an AWS call during apply | A service calls another service with the caller's identity, or a missing action | Compare with the AWS managed policy for that service and the service reference JSON before adding a scoped action |
| `AccessDenied` on `AssumeRoleWithWebIdentity` | A trust claim differs (`sub`, `ref`, `job_workflow_ref`, environment) | Compare the job's claims with the bootstrap trust locals; a renamed workflow file needs a bootstrap re-apply |
| harden-runner names a blocked host and the step fails to connect | The job's allowlist misses a host | A short PR that adds the exact `host:port`, built from the allowed expressions; never switch to `audit` |
| `429` or `toomanyrequests` from `public.ecr.aws` | Anonymous ECR Public quota on shared runners | No config change; the build falls back to the mirror |
| Dependabot `DENIED: Not Authorized` on a docker update | Dependabot cannot read `public.ecr.aws` (tradeoffs 17) | The `docker` ecosystem is off; bump digests with `pin-versions` |
| `-lockfile=readonly` refuses | Lock file missing a platform or provider | `terraform providers lock` for both platforms (skill `pin-versions`) |
| A `repo-guard` policy check fails | The change broke a written rule | Fix the workflow, not the policy. Change the policy only through an ADR decision |
| A self-test passes but for the wrong reason | The test accepts any failure | Make it require the specific error |
| A shell self-test fails on a Mac but passes in CI | macOS `/bin/bash` is 3.2 | Rewrite without bash 4 features; `make check` must pass on both |

If nothing matches, find the earliest failing step, reproduce it offline (`make check`, or the script with its
self-test), and only then propose a fix.

## 4. Act

- Code or workflow fixes go on a branch and a PR (skill `pr-conventions`). Re-runs and approvals are for the
  user in the web UI (the PAT has Actions read-only).
- Anything that applies, destroys or sets a secret value goes to the user as a command (skill
  `checkpoint-commands`).
- Record a new cause in the lessons log the moment it is diagnosed: symptom, cause, fix, lesson. Use Edit, not a
  shell heredoc (the guard hook scans command text).
