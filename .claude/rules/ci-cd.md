---
paths:
  - ".github/**"
---

# CI/CD

Read `docs/reference/standards/ci-cd.md` before editing. Lab-specific points it builds on:

- Every third-party action pinned to a full commit SHA with the version in a comment (skill `pin-versions`).
- `harden-runner` first in every job; `block` with exact hosts on jobs that assume a role. No wildcard family
  (such as `*.execute-api`): canary probes go through the Lambda API (ADR 0012, review M1).
- Release order per version: publish by digest, smoke-invoke that version, then move alias `live` (L7). A
  canary is judged on probe status codes per route, not only on the `Errors` metric.
- Workflow file names are part of the OIDC trust (`job_workflow_ref`): renaming one needs a bootstrap re-apply.
- `repo-guard` policies change only through an ADR decision; fix the workflow, not the policy.
