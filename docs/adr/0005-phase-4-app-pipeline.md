# ADR 0005: Phase 4 app pipeline

- Status: accepted
- L2 (pin the workflow file, not its name) is resolved by ADR 0007 S2; Q1 (harden-runner insights) is checked at its checkpoint.
- F23 (deploy-registered revisions left at teardown) is resolved by ADR 0006 G12.
- Date: 2026-10-26 (accepted the same day)

## Context

Phase 4 adds the app pipeline:

- `app-ci.yml` runs on pull requests that touch `app/**`. It builds the image, runs the tests and scans the image. It never pushes and never touches AWS.
- `app-deploy.yml` runs on `main`. It builds once, pushes to the dev ECR, registers a task definition revision that references the image by digest, updates the ECS service and waits for the rollout.

The phase ends at a checkpoint. A PR changes one line of the app. CI passes, the PR is merged, and the user approves the deploy. The ALB then shows the new SHA and colour, `APP_ENV: dev` and `secret_loaded: yes`, and the running task definition references `@sha256:`, not a tag.

Requirements covered:

| ID | What Phase 4 must deliver |
|---|---|
| FR-10 | `app-ci.yml`: on a PR touching `app/**`, build the image, run the tests, scan the image with a scanner pinned by version and checksum. No push |
| FR-11 | `app-deploy.yml`: on push to `main` touching `app/**`, build once, tag with the git SHA, push to dev ECR, register a task definition revision that references the image digest, update the service, wait for stability |
| FR-14 | Trunk-based: a merge to `main` deploys dev. Nothing deploys from a branch or a PR |
| FR-15 | dev uses ECS `ROLLING` with the deployment circuit breaker and rollback (already in the module; Phase 4 must detect a rollback instead of reporting success) |
| FR-5 (consumer) | The deploy role stays as bootstrapped: one ECR repo, one family, one service, PassRole on the two ECS roles, no Secrets Manager |
| NFR-1 | No AWS keys. The deploy role ARN is an environment `dev` secret (ADR 0004 E25 deviation from the literal "variables") |
| NFR-2 | `permissions: {}` at workflow level. `id-token: write` only on the deploy job |
| NFR-3 | Every action pinned by full SHA. Trivy and hadolint are pinned by version and SHA-256 |
| NFR-4 | harden-runner is step 1 of every job, `egress-policy: audit` |
| NFR-5 | Lock files unchanged (no new Terraform roots or providers) |
| NFR-9 | Claude never applies, sets secrets or approves. The user runs every checkpoint command |

Constraints carried over:

- **ADR 0001:** D1 (public repo), D2 (no account ID in git), D8 (no AWS credentials in the agent shell), D9 (disjoint ownership), D14 (orchestrator owns docs), D15 (thin Makefile).
- **ADR 0002:**
  - B13 deploy trust: `sub ...:environment:dev`, `ref refs/heads/main`, plus the E2 `workflow = app-deploy`.
  - B19 deploy policy (`infra/terraform/bootstrap/iam_deploy.tf`).
  - B16 guardrails: G1 denies `GetSecretValue`.
  - B20 wildcard list.
  - Residual risks R2 and R3.
- **ADR 0003:** C3 (fork and Dependabot skip), C5 (`ubuntu-24.04`), C9 and C10 (mask the account; account-bearing values are secrets).
- **ADR 0004:**
  - E10: ECR is IMMUTABLE with scan on push and keeps the last 10 images.
  - E13: the placeholder `container_command`, and the Fargate `/tmp` lesson that a task-scoped volume is owned by root.
  - E14: `ignore_changes = [task_definition]` and `wait_for_steady_state = false`.
  - E25: GitHub configuration.
  - E29: `install-ci-tools.sh` and `ci-tools.sha256`.
  - Consequences (a) to (d): the name `app-deploy`; `UpdateService` must pass `taskDefinition`; remove `container_command` first; Terraform revisions reach the service only through the next deploy.
  - The decision log: `repo-guard` runs on every PR, and the ruleset requires a PR.

Repo state read for this ADR (branch `phase-4-app-pipeline` at `a656d41`):

- **App.** `app/src/board.py` writes nothing to disk. It has no `tempfile`, no file I/O, and `PYTHONDONTWRITEBYTECODE=1`. It reads the image digest from `ECS_CONTAINER_METADATA_URI_V4` field `ImageID`. It has no SIGTERM handler, and it runs as PID 1.
- **Dockerfile.** `app/Dockerfile` is multi-stage. The runtime stage copies from the `test` stage, so building the runtime image runs the unit tests. It takes a `GIT_SHA` build argument, runs as `USER 10001:10001`, and pins the base image by its Docker Hub index digest.
- **Deploy role.** `infra/terraform/bootstrap/iam_deploy.tf` matches the facts already established. It includes `DescribeServices` on the one service and `TagResource` limited to `ecs:CreateAction = RegisterTaskDefinition`.
- **Placeholder.** `infra/terraform/envs/dev/terraform.tfvars` still carries the placeholder `container_command`. The module adds `command` only when that value is non-null.
- **Tools.** `mise.toml` already pins `trivy = "0.76.1"` and `hadolint = "2.15.1"`. `scripts/ci-tools.sha256` has only terraform and tflint.

Findings from current docs that shape this ADR:

1. **The Trivy ecosystem was compromised in March 2026** (GHSA-69fq-xp46-6x23, CVE-2026-33634, Critical):
   - every `aquasecurity/trivy-action` tag from 0.0.1 to 0.34.2;
   - every `setup-trivy` tag;
   - Trivy binary v0.69.4;
   - some Docker Hub images.

   The payload stole CI secrets before running a normal scan. Trivy v0.76.1 (2026-10-21) is the current release; it is a security update for the eMudhra CA compromise. Releases ship a `.sigstore.json` bundle for `cosign verify-blob`.
2. **`aws ecs wait services-stable` reports success after a circuit-breaker rollback.** Its condition is "one deployment and runningCount == desiredCount", and that is also true once ECS has rolled back to the old revision. The deployment's `rolloutState` (`IN_PROGRESS | COMPLETED | FAILED`) is the real signal.
3. **The deploy action's wait relies on deployment IDs**, so a rollback shows up only indirectly. `amazon-ecs-deploy-task-definition` v2.6.4 calls `waitUntilServicesStable`, then checks the new deployment ID, which is missing after a rollback or `FAILED`. It works, but the logic sits inside a third-party action that holds AWS credentials.
4. **The render action cannot remove `command` and copies Terraform's tags.** `amazon-ecs-render-task-definition` v1.9.1 can describe a family (`include: ['TAGS']`) and strips the read-only fields. It copies Terraform's tags, including `ManagedBy=terraform`, and it can set `command` but not remove it.
5. **Task metadata v4 `ImageID` is "the SHA-256 digest of the image manifest".** If the pushed artifact is a single-platform manifest, the ECR `imageDigest`, the task definition `@sha256:`, `DescribeTasks imageDigest` and the app's `/version` all show the same value. If it is an index (multi-arch or attestations), they can differ. The container `Image` field holds the full ECR URI, which includes the account ID, so the app must never show it.
6. **The response has a read-only field that the deploy action does not strip.** The `RegisterTaskDefinition` response includes `deleteRequestedAt`, which is missing from the action's ignore list. The request accepts exactly: `containerDefinitions`, `cpu`, `enableFaultInjection`, `ephemeralStorage`, `executionRoleArn`, `family`, `inferenceAccelerators`, `ipcMode`, `memory`, `networkMode`, `pidMode`, `placementConstraints`, `proxyConfiguration`, `requiresCompatibilities`, `runtimePlatform`, `tags`, `taskRoleArn`, `volumes`. Fargate requires task-level `cpu` and `memory`.
7. **A first service deployment has nothing to roll back to.** "When the deployment circuit breaker does not find a deployment that is in a COMPLETED state, the circuit breaker does not launch new tasks and the deployment is stalled." With desired count 1, the threshold is 3 failures. A later `UpdateService` starts a new deployment normally.
8. **PID 1 ignores signals that have the default action** (Docker run reference). `python src/board.py` installs no SIGTERM handler. So ECS waits the full stop timeout (30 s default) and then kills the task. Every rolling deploy and every `docker compose down` is slower than it needs to be.
9. **Concurrency** allows one running and one pending run per group. A newer pending run cancels the older pending one (`queue: single` is the default).
10. **Environment secrets are released only after approval**, and only branches matching the deployment branch policy can deploy.
11. **ECR rejects a push to an existing immutable tag** with `ImageTagAlreadyExistsException`.
12. **Runner `ubuntu-24.04`** (image 20261023.334.3): Docker 28.0.4, Buildx 0.38.0, AWS CLI 2.37.13, jq 1.7. The default `docker` buildx driver produces single-platform images without attestations.
13. **GitHub artifact attestations on public repos** go to the Sigstore Public Good instance. The bundle is "written to an immutable transparency log that is publicly readable". For an ECR image, the attestation subject name is the registry URI, which contains the account ID. Whether that name is readable from the public log was not verified.
14. **harden-runner telemetry likely exposes the account ID.** On a public repo the insights page is likely public; StepSecurity says private-repo insights are not public. In audit mode it records the destination hostnames, and `disable-telemetry` is meaningful only with `block`. The ECR registry host `<account>.dkr.ecr.<region>.amazonaws.com` contains the account ID. The Phase 3 state bucket host `sis-dev-tfstate-<account>-...` already does. This is a possible existing exposure (Q1).

## Decision

### A. Delivery, ownership of the task definition, ordering

| # | Decision | Why / source |
|---|---|---|
| F1 | **Two PRs.** **PR 1** (`phase-4-app-pipeline`): app changes (F20), both workflows, the scripts, the tool pins, and removing `container_command` (F2). **PR 2** (the checkpoint): a one-line app change, opened by the orchestrator after PR 1 is merged and deployed. It proves that a routine app-only change runs `app-ci`, skips `terraform-iac`, and deploys after one approval. Merging PR 1 starts two approval-gated runs: `terraform-iac` apply (the `envs/dev` tfvars changed, and because the stack is torn down this re-creates it) and `app-deploy` (`app/**` changed). The user approves them in that order (checkpoint step 4). | PLAN Phase 4.2; ADR 0004 consequence (c) |
| F2 | **Terraform owns the shape of the task definition; app-deploy owns only `image`.** <br>- Remove `container_command` completely: the value in `envs/dev/terraform.tfvars`, the variable in `envs/dev/variables.tf`, the argument in `main.tf`, the module variable, and the `merge(...)` in `modules/app-ecs/ecs.tf`. Remove the module tests for it and add a test that the container has no `command`.<br>- `container_image` keeps the digest-pinned ECR Public `python:3.13-slim` placeholder, because ECR is empty when Terraform creates the service. With no command, that image exits at once. So **the first deployment after a create fails and stalls by design** (Finding 7), and the first `app-deploy` brings the service up.<br>- This replaces ADR 0004 B5's "force a new deployment" with "run app-deploy".<br>- Keep `ignore_changes = [task_definition]` and `wait_for_steady_state = false`. Keep the `/tmp` task volume as is: the app never writes to it, and F11 makes CI fail if it ever tries. | E13 Phase 4 note; ADR 0004 consequences (c) and (d) |
| F3 | **Render from the family's latest ACTIVE revision** (`describe-task-definition --task-definition sis-dev-app`), not from the service's current revision. The family's latest revision always carries Terraform's newest shape. After a re-create, the secret ARN has a new random suffix and only Terraform's new revision has it. A Terraform change to env, roles or logging goes live with the next deploy (consequence (d)). | Finding 6; ECS family revisions are monotonic |
| F4 | **Render with `scripts/render-task-def.sh` (jq), not the render action.** Input: the describe JSON, the image URI with digest, and the git SHA. Output: the register input JSON. Rules:<br>(a) keep only the documented request keys (Finding 6);<br>(b) fail on any top-level key that is neither a request key nor a known read-only key (`taskDefinitionArn`, `revision`, `status`, `requiresAttributes`, `compatibilities`, `registeredAt`, `registeredBy`, `deregisteredAt`, `deleteRequestedAt`), so a new API field fails loudly;<br>(c) require exactly one container, named `app`;<br>(d) fail if `command` or `entryPoint` is present ("Terraform task definition still has a command; merge and apply the infra change first"), which enforces the F1 order;<br>(e) require task-level `cpu` <= 512 and `memory` <= 1024, so a breach fails before IAM refuses it;<br>(f) require `executionRoleArn` and `taskRoleArn` to end in `role/sis-dev-ecs-exec` and `role/sis-dev-ecs-task`;<br>(g) require `secrets` to be exactly `[{name: APP_API_KEY, valueFrom: arn:aws:secretsmanager:<region>:<12 digits>:secret:sis/dev/app-api-key-<6 chars>}]`;<br>(h) require the image argument to match `^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/sis-dev-app@sha256:[0-9a-f]{64}$` and set it;<br>(i) set `tags` to `Project=ship-it-safely`, `Env=dev`, `ManagedBy=app-deploy`, `GitSha=<sha>`.<br>Nothing is printed: the JSON holds ARNs with the account ID. | Findings 4, 6; deploy role `ecs:task-cpu`/`ecs:task-memory` caps and `TagRegisteredTaskDef` |
| F5 | **No AWS deploy actions. Use the preinstalled AWS CLI** for ECR login, describe, register, update and wait:<br>- fewer third-party code paths hold credentials (lesson of Finding 1);<br>- the waiter needs `rolloutState` (Findings 2, 3);<br>- the render action copies Terraform tags and cannot remove `command` (Finding 4);<br>- the repo already uses the CLI.<br>The AWS CLI version is printed in the log (ADR 0003 C11). Current pins, recorded for a later reversal:<br>- `aws-actions/amazon-ecr-login@03f1aad4c6c7ffd436567f42f9384779290529bd # v2.1.7`<br>- `aws-actions/amazon-ecs-render-task-definition@8d79160660ad39c402a16e5fc7cd2a32e8f7d6b7 # v1.9.1`<br>- `aws-actions/amazon-ecs-deploy-task-definition@a00d4d57ac0de1a99b39fe469f3d898d38717c2b # v2.6.4`<br>All three run on node24 and are AWS-owned; they are rejected on scope, not on trust. | Findings 2 to 4, 12 |

### B. Build, scan, smoke (both workflows)

| # | Decision | Why / source |
|---|---|---|
| F6 | **Build with the runner's Docker and BuildKit; no `docker/setup-buildx-action` and no `docker/build-push-action`.** Command: `docker buildx build --platform linux/amd64 --provenance=false --sbom=false --load --build-arg GIT_SHA="$GIT_SHA" -t "sis-app:${GIT_SHA}" app`. The default `docker` driver gives a single-platform manifest, and the explicit flags keep it that way if the builder changes. That keeps one digest everywhere (Finding 5). No layer cache: the image is tiny, and a `type=gha` cache would need the `docker-container` driver and adds cache-poisoning risk. Pins recorded for reversal: `docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1`, `docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0`. | Finding 12; ADR 0004 Q6 (`X86_64`) |
| F7 | **The tests run inside the build.** The runtime stage copies from the `test` stage, so a failing unit test fails the build in both workflows. The deploy therefore re-runs the tests on the exact merge commit. | `app/Dockerfile` |
| F8 | **Trivy as a checksum-verified binary, never `trivy-action` or `setup-trivy`.**<br>- `scripts/install-ci-tools.sh` installs `trivy_0.76.1_Linux-64bit.tar.gz`, SHA-256 `c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0` (from the official `trivy_0.76.1_checksums.txt`). Before committing the hash, the devops engineer also checks the release once with `cosign verify-blob` against the `.sigstore.json` bundle (identity `https://github.com/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v0.76.1`, issuer `https://token.actions.githubusercontent.com`).<br>- **Scan** with `scripts/scan-image.sh <image> <out dir>`: run `docker save` to a tar, then `trivy image --input <tar> --scanners vuln,secret --pkg-types os,library --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --format json --output <out>/trivy.json --no-progress --disable-telemetry --timeout 10m --cache-dir "$RUNNER_TEMP/trivy-cache"`. Then run `trivy convert --format table` on the report for the log, and write the counts to the step summary.<br>- `--input` means Trivy never falls back to a registry pull.<br>- The vulnerability database comes from the default `mirror.gcr.io/aquasec/trivy-db:2`, with ghcr as fallback. No `actions/cache`.<br>- **Exceptions** go in `app/.trivyignore`. Each entry needs a comment with the reason and an `exp:YYYY-MM-DD` date. Start with none. | Finding 1; Trivy CLI and filtering docs |
| F9 | **A scanner never runs while credentials are present.** `app-ci` has no secrets and no `id-token`. In `app-deploy`, build, smoke test and Trivy all run **before** `configure-aws-credentials`, and none of those steps has a secret in `env:`. If a compromised scanner ran, it would see only a `contents: read` token. | Finding 1 (the payload stole CI secrets) |
| F10 | **No SARIF or code-scanning upload in Phase 4.** It would need `security-events: write`, `github/codeql-action/upload-sarif` and fork handling. The table goes to the log and the counts to the step summary. Revisit in Phase 6. | NFR-2 (least privilege) |
| F11 | **Container smoke test** (`scripts/app-smoke.sh <image> <git sha>`) mirrors Fargate. It runs the image with:<br>- `--read-only` and `--user 10001:10001`;<br>- `--tmpfs /tmp:rw,mode=0755,uid=0,gid=0` (owned by root and not writable by 10001, like the Fargate task volume);<br>- `--cap-drop ALL --security-opt no-new-privileges`;<br>- `-e APP_ENV=ci -e APP_API_KEY=<fake value made at run time>`.<br>It asserts that:<br>- `docker inspect` user is `10001:10001`;<br>- `GET /health` returns 200;<br>- `GET /version` `git_sha` equals the argument;<br>- `GET /` contains `secret_loaded: yes` and not the fake key;<br>- `GET /admin` without the key returns 401;<br>- `docker stop -t 10` finishes within 5 s with exit code 0 (needs F20 SIGTERM).<br>The container is always removed. | E13 lesson; Finding 8 |
| F12 | **Other checks in `app-ci`:**<br>- hadolint as a checksum-verified binary (`hadolint-linux-x86_64` v2.15.1, SHA-256 `c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507`, saved as `hadolint_2.15.1_linux_x86_64`);<br>- ruff (check and format) and mypy through the hash-locked pre-commit venv that `repo-guard` already uses (`scripts/ci-requirements.txt`). | CLAUDE.md pre-PR checks; NFR-3 |

### C. `.github/workflows/app-ci.yml`

| # | Decision |
|---|---|
| F13 | `name: app-ci`.<br>**Trigger:** `pull_request` only (`branches: [main]`). `paths`: `app/**`, `.github/workflows/app-ci.yml`, `scripts/install-ci-tools.sh`, `scripts/ci-tools.sha256`, `scripts/app-smoke.sh`, `scripts/scan-image.sh`, `mise.toml`.<br>**Workflow settings:** `permissions: {}`; `concurrency: { group: app-ci-${{ github.ref }}, cancel-in-progress: true }` (no AWS state).<br>**One job, `build-test-scan`:** `runs-on: ubuntu-24.04`, `timeout-minutes: 15`, `permissions: contents: read` only. No `environment`, no `id-token`, no secrets, so it also runs for fork and Dependabot PRs (no C3 skip needed).<br>**Steps:**<br>1. harden-runner (audit)<br>2. checkout with `persist-credentials: false`<br>3. `scripts/install-ci-tools.sh "$RUNNER_TEMP/tools" trivy hadolint`<br>4. `hadolint app/Dockerfile`<br>5. hash-locked pre-commit venv, then `pre-commit run ruff-check --all-files`, `ruff-format`, `mypy`<br>6. build (F6). `GIT_SHA` comes from `github.event.pull_request.head.sha` through `env:`<br>7. smoke (F11)<br>8. scan (F8)<br>9. summary: commit, Trivy counts, "not pushed"<br>No `docker login`, no push, no `upload-artifact`. **Not a required status check** (path-filtered, so it would stay Pending on other PRs; see Q5). |

### D. `.github/workflows/app-deploy.yml`

| # | Decision |
|---|---|
| F14 | `name: app-deploy` (exactly; deploy trust E2).<br>**Triggers:** `push` (`branches: [main]`; `paths`: `app/**`, `.github/workflows/app-deploy.yml`, `scripts/render-task-def.sh`, `scripts/ecs-wait-deployment.sh`, `scripts/check-aws-config.sh`), and `workflow_dispatch` with no inputs, to deploy `main` HEAD after a re-create. Shared tooling changes (`install-ci-tools.sh`, the checksum file, the smoke and scan scripts) do not trigger a deploy; `app-ci` covers them on the PR.<br>**Workflow settings:** `permissions: {}`; `concurrency: { group: app-deploy-dev, cancel-in-progress: false }`. A newer pending run replaces an older pending one, so the latest commit wins, and a running deploy is never cancelled (Finding 9).<br>**One job, `deploy`:** `if: github.ref == 'refs/heads/main'`, `environment: dev`, `runs-on: ubuntu-24.04`, `timeout-minutes: 30`, `permissions: { contents: read, id-token: write }`. |
| F15 | **Step order** (the order is load-bearing):<br>1. harden-runner (audit).<br>2. Checkout (`persist-credentials: false`).<br>3. `scripts/install-ci-tools.sh "$RUNNER_TEMP/tools" trivy`.<br>4. Build (F6) with `GIT_SHA=$GITHUB_SHA` (full 40 hex).<br>5. Smoke (F11).<br>6. Scan (F8). The gate: a fixed HIGH or CRITICAL finding blocks the deploy (Q4).<br>7. **Check configuration** with `scripts/check-aws-config.sh sis-dev-gha-deploy`. It reads `ROLE_ARN` (`secrets.AWS_DEPLOY_ROLE_ARN`, environment `dev`), `ACCOUNT` (`secrets.AWS_ACCOUNT_ID_DEV`) and `REGION` (`vars.AWS_REGION`) from `env:`. It masks the account, checks the ARN against `^arn:aws:iam::[0-9]{12}:role/<name>$` and checks that the ARN's account equals `ACCOUNT`.<br>8. `configure-aws-credentials` with session `gha-deploy-<run_id>-<attempt>`, `mask-aws-account-id: true`, `retry-max-attempts: 3`.<br>9. **Guardrail N4:** `aws secretsmanager get-secret-value --secret-id sis/dev/app-api-key` must fail with `AccessDeniedException`. Success fails the job. `ResourceNotFoundException` fails the job too ("dev stack or secret missing"). Same capture pattern as E26.<br>10. **Preflight** (F16).<br>11. **Push** (F7a below).<br>12. **Render** (F4) into `$RUNNER_TEMP/td.json`.<br>13. **Register:** `aws ecs register-task-definition --cli-input-json "file://$RUNNER_TEMP/td.json" --query taskDefinition.taskDefinitionArn --output text`.<br>14. **Update:** `aws ecs update-service --cluster sis-dev-cluster --service sis-dev-app --task-definition "$TD_ARN" --query 'service.deployments[?status==`PRIMARY`].id' --output text`. Always with the revision ARN (contract (b)); never `--force-new-deployment` alone.<br>15. **Wait** (F17).<br>16. **Summary** (`if: always()`, F18).<br>17. `docker logout` and remove `DOCKER_CONFIG` (`if: always()`). |
| F7a | **Push, once, by immutable tag, digest from ECR:**<br>- Set `REGISTRY=${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com`. It is masked, because the account is masked.<br>- `export DOCKER_CONFIG="$RUNNER_TEMP/docker-config"` (through `$GITHUB_ENV`) so the token never lands in `~/.docker`.<br>- `aws ecr describe-images --repository-name sis-dev-app --image-ids imageTag=$GITHUB_SHA`:<br>&nbsp;&nbsp;- if the tag exists (a re-run), skip the push and reuse the digest, so a rebuilt image never replaces the scanned one;<br>&nbsp;&nbsp;- if not, run `aws ecr get-login-password \| docker login --username AWS --password-stdin "$REGISTRY"`, `docker tag`, then `docker push "$REGISTRY/sis-dev-app:$GITHUB_SHA"`.<br>- Then read `imageDigest` and `imageManifestMediaType` from `describe-images`. The job fails unless the digest matches `^sha256:[0-9a-f]{64}$` and the media type is a single image manifest (`application/vnd.docker.distribution.manifest.v2+json` or `application/vnd.oci.image.manifest.v1+json`), not an index (Finding 5). |
| F16 | **Preflight: fail clearly if the stack is not up.** `aws ecs describe-services --cluster sis-dev-cluster --services sis-dev-app`. On `ClusterNotFoundException`, `failures[].reason == MISSING`, or `status != ACTIVE`: `::error::dev stack is not up. Re-create it (terraform-iac, Run workflow), set the secret value, then run app-deploy (Run workflow).` and exit 1. It **fails rather than skips**, so a green run always means "deployed" (Q2). It does not build a list of deployments or ARNs into the log. |
| F17 | **Wait: `scripts/ecs-wait-deployment.sh <cluster> <service> <td arn> <timeout s>`** (default 1200 s, poll 15 s). It never uses `aws ecs wait services-stable` alone (Finding 2). On each poll it calls `describe-services` and finds the deployment whose `taskDefinition == TD_ARN`:<br>- `COMPLETED`, with the PRIMARY deployment on `TD_ARN`: success.<br>- `FAILED`: error with `rolloutStateReason` and the last 5 service event messages (12-digit runs replaced by `<redacted>`); circuit-breaker rollback is in progress.<br>- Deployment gone and PRIMARY on another revision: error "rolled back by the circuit breaker".<br>- `IN_PROGRESS`: keep polling.<br>- Timeout: error that states the state at timeout.<br>The decision logic sits in a pure function that reads describe JSON from stdin (`--evaluate <td arn>`), so `ci-selftest.sh` can test it with fixtures. |
| F18 | **Summary and log hygiene.** The step summary holds:<br>- the commit SHA;<br>- the image digest;<br>- the revision as `sis-dev-app:<n>` (`${TD_ARN##*/}`);<br>- the result;<br>- the Trivy counts;<br>- the role line `assumed-role/sis-dev-gha-deploy/<session>` (`${arn#*:assumed-role/}`).<br>Before it is written, the text must not contain the account value or any `(^\|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]\|$)` run. Raw describe output, the task definition JSON and the image URI are never echoed. No `${{ }}` in `run:`. No `upload-artifact`. |

### E. IAM (no bootstrap change)

| # | Decision |
|---|---|
| F19 | **The deploy role is sufficient as applied. No bootstrap change and no re-apply.** Audit of every call app-deploy makes:<br><br>- `sts:GetCallerIdentity`: needs no permission.<br>- `ecr:GetAuthorizationToken`: `EcrAuth`, `*` (B20; no resource-level support).<br>- `ecr:DescribeImages`, `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` (and `BatchGetImage` if the client checks the manifest): `EcrPushOneRepo`, `repository/sis-dev-app`.<br>- `ecs:DescribeServices` (preflight and wait): `DescribeOneService`, one service ARN.<br>- `ecs:DescribeTaskDefinition`: `DescribeTaskDef`, `*` (B20). No `include TAGS`, so `ListTagsForResource` is not needed.<br>- `ecs:RegisterTaskDefinition`: `RegisterTaskDef`, `task-definition/sis-dev-app:*`, cpu <= 512 and memory <= 1024 at task level (F4e). With tags it also needs `ecs:TagResource` (`TagRegisteredTaskDef`, `ecs:CreateAction = RegisterTaskDefinition`) and `iam:PassRole` on exactly `sis-dev-ecs-exec` and `sis-dev-ecs-task` with `iam:PassedToService = ecs-tasks.amazonaws.com` (`PassTaskRoles`).<br>- `ecs:UpdateService`: `UpdateOneService`, one service ARN, `ArnLike ecs:task-definition = task-definition/sis-dev-app:*` (F15 step 14 always passes it).<br>- `secretsmanager:GetSecretValue` (N4): explicit deny from guardrail G1, as intended.<br><br>**Not added:**<br>- `ecs:DescribeTasks` and `ListTasks`: service events and `rolloutStateReason` are enough; the user reads task details as admin.<br>- `ecr:DescribeRepositories`: the preflight uses ECS; a missing repository surfaces as `RepositoryNotFoundException` from `DescribeImages`.<br>- `elasticloadbalancing:Describe*` for an in-pipeline URL check (Q6).<br><br>Wildcards stay limited to the two B20 actions. `iam:PassRole` is unchanged: exact ARNs plus `PassedToService`. |

### F. App, provenance, tooling

| # | Decision |
|---|---|
| F20 | **App changes (backend-dev):**<br>(a) **SIGTERM handler** in `__main__`: stop `serve_forever` and close the socket. The process then exits with code 0 within a second (Finding 8). That makes rolling deploys and `docker compose down` faster.<br>(b) **Never show the metadata `Image` field.** It holds the ECR URI with the account ID, and the ALB is public. Only `ImageID` (`sha256:...`) is shown. Add a test for this.<br>(c) **No disk writes** (already true); F11 enforces it in CI.<br>(d) **OCI labels** in the runtime stage: `org.opencontainers.image.revision=$GIT_SHA` and `org.opencontainers.image.source=https://github.com/trungleviet-agilityio/ship-it-safely`.<br>(e) **Base image source:** switch both `FROM` lines to `public.ecr.aws/docker/library/python:3.13-slim@sha256:<current index digest>`. That is the same official image, without Docker Hub pull limits, and matches E13. If Trivy finds fixed HIGH or CRITICAL issues, bump to the newest index digest (Q3).<br>(f) `APP_ENV=dev` stays a Terraform task definition env var, and `/health` stays the ALB path; no change. The colour is derived from `GIT_SHA`, so every deploy is visibly different without touching `APP_COLOR`. |
| F21 | **Provenance: defer attestations, SBOM and signing to Phase 6.** Phase 4 provides:<br>- digest pinning end to end;<br>- an immutable git-SHA tag;<br>- OCI revision labels;<br>- the Trivy gate before push;<br>- ECR basic scan on push.<br>GitHub artifact attestations and keyless cosign both write to the public Sigstore log, and the ECR subject name contains the account ID (Finding 13). Phase 6 must first check what the log exposes, or sign a subject without the registry host. A Trivy CycloneDX SBOM also waits for Phase 6. |
| F22 | **Scripts and tooling (devops-engineer):**<br>- `scripts/install-ci-tools.sh <dest> [tool...]`: tools are `terraform`, `tflint`, `trivy`, `hadolint`; the default stays `terraform tflint`, so `terraform-iac.yml` keeps working unchanged. Versions come from `mise.toml`.<br>- `scripts/ci-tools.sha256`: add the two lines from F8 and F12.<br>- New scripts: `check-aws-config.sh`, `app-smoke.sh`, `scan-image.sh`, `render-task-def.sh`, `ecs-wait-deployment.sh`.<br>- `ci-selftest.sh`: add fixtures for the render and wait scripts (it already runs in `repo-guard` on every PR).<br>- `Makefile`: add `image`, `smoke` and `scan` (local Docker, each one line calling a script). They stay out of `check`, which needs no Docker.<br>- **Do not edit `terraform-iac.yml`** in this phase. Its push paths would start an extra apply, and the code simplifier's consolidation stays deferred. |
| F23 | **Retention:** ECR keeps 10 images (E10), and each deploy pushes one single-platform image, so the rollback horizon is 10 deploys. Deploy-registered revisions are not deregistered at teardown (resolved by ADR 0006 G12: `terraform-destroy` deregisters them). The deploy role cannot deregister, and inactive revisions cost nothing. Phase 5 decides whether `terraform-destroy` cleans them up. |

### Least privilege summary

| Item | Value | Wildcards |
|---|---|---|
| Role assumed | `sis-dev-gha-deploy` only, only in `app-deploy` job `deploy` (environment `dev`, `main`) | none added |
| Trust | unchanged: `aud`; `sub = <P>:environment:dev`; `repository_id`; `repository_owner_id`; `ref = refs/heads/main`; `workflow = app-deploy` | none |
| Permissions | unchanged (F19) | `ecr:GetAuthorizationToken`, `ecs:DescribeTaskDefinition` (B20) |
| `iam:PassRole` | exactly `sis-dev-ecs-exec`, `sis-dev-ecs-task`, `PassedToService = ecs-tasks.amazonaws.com` | none |
| GitHub tokens | `app-ci`: `contents: read`. `app-deploy`: `contents: read`, `id-token: write` | none |
| Secrets in scope | `app-ci`: none. `app-deploy`: `AWS_DEPLOY_ROLE_ARN` (env), `AWS_ACCOUNT_ID_DEV`; only in steps 7 onward, after the scan | n/a |

### Pins and versions (verified 2026-10-26)

| Item | Version | Pin | Used |
|---|---|---|---|
| `step-security/harden-runner` | v2.22.2 (latest) | `dc2769abcc0fcfbadfc1df54081c1608579ef6b2` | yes |
| `actions/checkout` | v7.0.1 (latest) | `3d3c42e5aac5ba805825da76410c181273ba90b1` | yes |
| `aws-actions/configure-aws-credentials` | v6.3.0 (latest) | `e1253824e5c10ff9df46874f81ed3ec929e19cfd` | yes (deploy) |
| `aws-actions/amazon-ecr-login` | v2.1.7 (2026-08-19) | `03f1aad4c6c7ffd436567f42f9384779290529bd` | no (F5) |
| `aws-actions/amazon-ecs-render-task-definition` | v1.9.1 (2026-10-05) | `8d79160660ad39c402a16e5fc7cd2a32e8f7d6b7` | no (F4, F5) |
| `aws-actions/amazon-ecs-deploy-task-definition` | v2.6.4 (2026-10-09) | `a00d4d57ac0de1a99b39fe469f3d898d38717c2b` | no (F5) |
| `docker/setup-buildx-action` | v4.4.1 (2026-09-16) | `f87e5991a6d7451dcb8d9637bfbc97413f497069` | no (F6) |
| `docker/build-push-action` | v7.4.0 (2026-09-15) | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` | no (F6) |
| `aquasecurity/trivy-action`, `setup-trivy` | n/a | never | no (Finding 1) |
| Trivy | 0.76.1 (2026-10-21) | SHA-256 `c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0` (`trivy_0.76.1_Linux-64bit.tar.gz`) | yes |
| hadolint | 2.15.1 (2026-07-31) | SHA-256 `c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507` (`hadolint-linux-x86_64`) | yes (CI) |
| AWS CLI, Docker, Buildx, jq | 2.37.13, 28.0.4, 0.38.0, 1.7 (runner image 20261023.334.3) | runner image, version printed in the log | yes |

The render and deploy tags are annotated. The SHAs above are the peeled commit objects: tag object `731946636f59...` points to `8d79160...`, and `ae89e14a...` points to `a00d4d5...`.

## Alternatives considered

- **`amazon-ecs-render-task-definition` plus `amazon-ecs-deploy-task-definition`.** This is the documented AWS path and needs less shell. Rejected:
  - two more node24 actions would hold AWS credentials;
  - the render action copies `ManagedBy=terraform` tags and cannot delete `command`;
  - the deploy action's ignore list misses `deleteRequestedAt`;
  - its rollback detection is indirect.

  The jq script is about 40 lines and is tested offline (F4, F17).
- **`aws-actions/amazon-ecr-login`.** It has a cleaner logout, but it is one more credentialed action for two CLI lines. The F15 step 17 logout plus a temporary `DOCKER_CONFIG` gives the same hygiene.
- **`docker/setup-buildx-action` and `build-push-action` with `type=gha` cache.** Faster rebuilds, but two more actions, the `docker-container` driver, and default provenance attestations would push an index and split the digests (Finding 5). Rejected for a roughly 50 MB stdlib image.
- **`trivy-action` or `setup-trivy`.** Rejected: GHSA-69fq-xp46-6x23 (every tag was replaced with credential-stealing code for about 12 hours), and NFR-3 asks for a checksum-verified binary anyway.
- **Trivy only in CI, not in deploy.** Faster deploys, and the vulnerability database could not block a merge-time deploy. Rejected (Q4): the deploy builds new bits on the merge commit, and those bits are what reach ECR.
- **Scan after assuming the role (scan what is pushed, from ECR).** Rejected by F9: the scanner would run with credentials in its environment.
- **Build and scan in an unapproved job, pass the image as an artifact, push in the approved job.** The approver would see the scan before approving. Rejected: artifacts on a public repo can be downloaded, it adds two actions, and a roughly 50 MB transfer per run. Revisit with prod promotion (Phase 7).
- **Keep the placeholder `container_command` in Terraform and strip `command` in the deploy render.** Terraform would own a healthy smoke revision, and a re-create would serve `/health` before the first deploy. Rejected: it contradicts ADR 0004 (c) and E13 ("until Phase 4"), it makes the deploy own two fields, and the re-create flow keeps an extra admin `force-new-deployment` step. F2 instead makes the stalled first deployment an explicit, documented state.
- **Render from the service's current revision.** After a re-create, an older deploy revision would carry a stale secret ARN, and Terraform changes to the task definition would never go live. Rejected (F3).
- **`aws ecs wait services-stable`.** It reports success after a rollback (Finding 2). Rejected.
- **Skip the deploy quietly when the stack is down.** A green run would then not mean "deployed". Rejected (Q2).
- **Add `ecs:DescribeTasks` or ELB describes to the deploy role.** Nicer messages and an automatic `/version` check. Rejected for Phase 4 to keep FR-5 tight and avoid a bootstrap re-apply (Q6).
- **GitHub artifact attestations or cosign now.** Rejected for Phase 4: a public log, and a subject name containing the account ID (F21).
- **Move ECR out of the torn-down stack** (bootstrap, or a persistent root), so images survive a teardown and Terraform could reference the app digest. It removes the stalled first deployment, but adds a new root and an apply-role scope change. Rejected for the lab.
- **ECS `initProcessEnabled` (tini) instead of an app SIGTERM handler.** Works on Fargate, but local `docker compose` would still need `init: true`. A five-line handler fixes both and is unit-tested.

## Consequences

- **Re-create flow after a teardown** (replaces ADR 0004 B5 and B6):
  1. Run `terraform-iac` with Run workflow, then approve.
  2. `put-secret-value`.
  3. Run `app-deploy` with Run workflow, then approve.
  4. Smoke check.

  No `force-new-deployment` with admin. Between steps 1 and 3 the service has a FAILED or stalled first deployment and the ALB returns 503. That is expected.
- **Drift by design.** Terraform's state tracks its own revision; the service runs deploy revisions. Terraform plans stay clean because of `ignore_changes`. A Terraform change to the task definition registers a new revision that goes live only with the next deploy (F3). `terraform-iac` and `app-deploy` can run at the same time. Terraform never sends `taskDefinition` on update, so the two do not fight. They use separate concurrency groups on purpose: a shared group would let one cancel the other's pending run.
- **Approval order on PR 1's merge:** `terraform-iac` first, then the secret, then `app-deploy`. If `app-deploy` is approved too early, it fails at the preflight with a clear message. Re-run the failed job afterwards; it rebuilds, because nothing was pushed.
- **A scan can block a deploy** on a newly published, fixed HIGH or CRITICAL vulnerability. The fix is a base digest bump (backend-dev), or an `app/.trivyignore` entry with a reason and an `exp:` date.
- **R3 (ADR 0002) is unchanged.** An approved deploy can run any image in the family with the execution role, and that role injects the secret. Mitigations:
  - environment approval;
  - `ref` and `workflow` pins;
  - the Trivy secret and vulnerability gate;
  - F4's guards (one container, no command override, exact roles and secret);
  - the guardrail deny on `GetSecretValue` for the deploy role itself (N4).
- **New R8 (Q1):** the harden-runner insights page for this public repo may list the ECR registry host and the state bucket host. Both contain the account ID. This is verified at the checkpoint, and Phase 6 (`block` mode with `disable-telemetry`) closes it.
- **Retention:** 10 images, and deploy revisions accumulate across teardowns (F23).
- **Cost.** These are estimates, not taken from a price page; check the AWS Pricing Calculator for ap-southeast-1.
  - Phase 4 adds cents: ECR storage for up to 10 images of about 50 MB, roughly 0.5 GB at about 0.10 USD per GB-month; a second task and public IPv4 for a few minutes per rolling deploy; a little more log volume.
  - Actions minutes are free on a public repo. ECR basic scanning is free.
  - The ALB and Fargate hours from Phase 3 still dominate, at about 1 to 2 USD per day while up. Tear down after every session.
- **Docs follow-up for the orchestrator (D14):**
  - **ADR 0004:** mark E13 and consequence (c) as done (the placeholder now never serves; F2), and mark B5 and B6 superseded by the re-create flow above.
  - **CODING_STANDARDS:** add:
    - scanners never run with credentials (F9);
    - "no `trivy-action`/`setup-trivy`; tools come from `install-ci-tools.sh`";
    - prefer the AWS CLI over credentialed actions;
    - single-platform images;
    - the `Image` metadata field is never shown;
    - SIGTERM handling.

    Also fix the stale "Terraform in `hashicorp/setup-terraform`" line under Tool versions (E29 replaced it).
  - **README:** add a Phase 4 section (pipeline, approval order, re-create flow, digest verification).
  - **`docs/diagrams`:** optional.

## Decision log (open questions resolved)

The user delegated these choices on 2026-10-26 ("decide by best practice and record pros and cons"). Each
can be reversed in a later ADR.

| Q | Decision | Pro | Con | Reversal cost |
|---|---|---|---|---|
| Q1 | Harden-runner insights may show hostnames with the account ID (ECR registry, state bucket): **verify at checkpoint step 8; if visible, accept until Phase 6**, then switch `apply` and `deploy` jobs to `egress-policy: block` with an allowlist | Keeps NFR-4 audit mode for one more phase, so the Phase 6 allowlist is built from real egress data | The account ID may be visible on a third-party page for a public repo until Phase 6 (AWS does not treat it as a secret; D2 is a hygiene rule) | Low: flip to `block` earlier if the user prefers |
| Q2 | When the dev stack is down, app-deploy **fails with a clear message** (F16) | Green always means "deployed"; a silent skip would hide that main is not running anywhere | A merge to `main` while the stack is torn down produces a red run, which is noise during teardown windows | Low: change the preflight to `::notice::` and exit 0 |
| Q3 | Dockerfile base moves to the **ECR Public mirror** of `python:3.13-slim`, pinned by index digest | Same official image, no Docker Hub pull limits in CI or on Fargate, and the same registry as the Phase 3 placeholder | Two names for one image across history; a future base bump must look up the digest on ECR Public, not Docker Hub | Low |
| Q4 | The Trivy gate **also blocks deploys**, not only PRs | It scans the exact bits that get pushed, and runs before any AWS credential exists (F9) | A new upstream CVE can block an urgent deploy; the escape hatch is a reviewed `.trivyignore` entry with an `exp:` date | Low |
| Q5 | `app-ci` is **not** a required status check | It is path-filtered, so docs-only PRs would sit Pending forever; `guard (no AWS)` stays the only candidate required check | A failing app-ci can still be merged if the reviewer ignores it; the deploy's own Trivy gate and tests (F7, Q4) then stop it before push | Low |
| Q6 | **No** ELB describe permissions for the deploy role in Phase 4 | Least privilege: a `COMPLETED` ECS rollout already means the ALB health checks passed | The pipeline cannot curl `/version` itself; the user checks the URL at the checkpoint | Low: a bootstrap change in Phase 7 if prod needs it |
| Q7 | **The orchestrator opens PR 2** (the one-line checkpoint change) after PR 1 is merged and deployed; the user merges and approves | Proves the routine path (app-only change: app-ci on PR, app-deploy after merge) with no infra noise | One more PR cycle in the phase | None |

**Build and verify findings (decided by the orchestrator on 2026-10-26, same delegation; the user also asked
for senior-level clean code, so duplication is fixed now, not deferred):**

| Finding | Decision | Pro | Con |
|---|---|---|---|
| Build: Trivy found 4 fixed HIGH in pip, setuptools and their vendored libraries on the newest base | **Uninstall pip, setuptools and wheel in the runtime stage** instead of a `.trivyignore` | Smaller attack surface, no ignore list to maintain, the app is stdlib only | No `pip` inside the container for debugging |
| Security H1: `id-token: write` and the environment apply to every step of a job, so build, smoke and Trivy could mint the deploy token; F9 as written did not hold | **Split app-deploy into `build-scan` (no id-token, no environment, no secrets) and `deploy`**; the image moves as a short-lived artifact whose sha256 is checked before `docker load`. This supersedes the F9 single-job wording | A compromised scanner or build step can no longer reach the deploy role or the job's secrets | The image tar becomes a public workflow artifact for one day (it holds no secret or account ID); about one extra minute per deploy |
| Security M1: the render step copied every container field except `image` | **Validate the shape Terraform owns** (container key allowlist; `user`, `readonlyRootFilesystem`, `environment` names, log group, `/tmp` volume pinned) | A tampered revision cannot persist through later deploys | Any intentional Terraform change to those fields needs the render rules updated in the same PR |
| Security L1: Trivy DB pulled by a moving tag | **Accept**; log the DB `UpdatedAt` and version in the summary | Fresh vulnerability data on every scan | A poisoned or stale mirror could hide findings; mitigated by visibility and ECR scan on push |
| Security L2: deploy trust pins the workflow `name:`, not its file path | **Defer to Phase 6** (evaluate `job_workflow_ref` with a reusable workflow) | No bootstrap change in this phase | A merged workflow named `app-deploy` could still use the role after one approval; `repo-guard`, review and the `main` ruleset limit it |
| Security L3 and reviewer 2, 3, 4, 5, 6, 8 | **Fix now**: fail-fast shells, wait loop tolerates 3 transient API errors with redacted stderr, job-level concurrency, N4 after the preflight without the unreachable branch, jq null guards, role name only in the summary, complete path filters | Correct failure messages and no displaced deploys | None worth noting |
| Re-review: the container-key allowlist was a hand-written guess and could reject the first real deploy (`versionConsistency` and other ECS defaults) | **Fix now**: allowlist = the botocore `ContainerDefinition` schema (commit pinned in the script) minus an explicit deny list (`privileged`, `linuxParameters`, `entryPoint`, `command`, `environmentFiles`, `repositoryCredentials`, `dockerSecurityOptions`, `links`, non-empty `volumesFrom`); realistic describe fixture | New ECS default fields cannot break deploys, dangerous ones are still refused by name | A future schema field needs a one-line refresh of the list (the command is in the script) |
| Re-review Lows: caps copied in `lib.sh`, isolation check never shown to fail, `terraform-iac` paths missing a script | **Fix now**: a self-test compares the caps with `iam_deploy.tf`, mutation tests prove the `build-scan` isolation check fails, every workflow's path filter is checked | Drift fails `make check` instead of a deploy | None worth noting |
| First real run: `app-deploy` build failed with `429 Too Many Requests` from ECR Public (anonymous pulls are rate limited per IP, and hosted runners share IPs) | **`build-image.sh` retries only transient registry errors** (429, 503, timeouts) with backoff 15, 30, 60 s; tests and Dockerfile errors fail on the first attempt. Self-tested with a stub `docker` | A shared-IP rate limit no longer turns a deploy red, and a real failure is never retried | A run that hits the limit takes up to about 2 extra minutes; authenticating to ECR Public would need credentials in `build-scan`, which H1 forbids |
| Second real run: retries could not help, ECR Public answered `toomanyrequests: Data limit exceeded` (anonymous data quota per shared runner IP). **Revises Q3** | **Keep the digest fixed in the Dockerfile and make only the registry an argument (`PYTHON_IMAGE`)**; `build-image.sh` tries ECR Public, then Docker Hub (same index digest, verified), and rounds of 30 and 60 s after that. Non-registry failures stay final | The build no longer depends on one registry's anonymous quota, and no mirror can change the bits because the digest is pinned | Docker Hub has its own anonymous limits; if both refuse, the run still fails after about 2 minutes. A pull-through cache or authenticated pulls need credentials in `build-scan`, which H1 forbids |
| Reviewer 1: possible hadolint DL3059 on two consecutive `RUN` lines | **No change**: `make lint` (hadolint) passes on the merged tree | No churn | Revisit if hadolint's default threshold changes |
| Clean code (simplifier and reviewer) | **Fix now**: inline deploy bash moves to `ecr-push.sh` and `ecs-preflight.sh` with a shared `run_capture` helper; one build, smoke and scan recipe for both workflows and `make`; one `assert-no-account-id.sh` and one `check-aws-config.sh` reused by `terraform-iac.yml`; deploy scripts take `ENV` so prod is a short second job, not a copy | Each piece is tested in `ci-selftest`; prod in Phase 7 reuses the scripts | More files in `scripts/`; `terraform-iac.yml` changes in this PR, which is acceptable because PR 1 already triggers an apply |

## Checkpoint commands (the user runs these; Claude never does, NFR-9)

Placeholders: `<DEV_ACCOUNT_ID>` (from `CLAUDE.local.md`), `<PR1>`, `<PR2>`.

```bash
REPO=trungleviet-agilityio/ship-it-safely
BUCKET="sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
aws sso login --profile sis-dev-admin
export AWS_PROFILE=sis-dev-admin AWS_REGION=ap-southeast-1
approve() {  # approve the pending dev deployment of a run
  local run="$1" note="$2" env_id
  env_id="$(gh api "repos/${REPO}/actions/runs/${run}/pending_deployments" --jq '.[0].environment.id')"
  gh api -X POST "repos/${REPO}/actions/runs/${run}/pending_deployments" \
    -F "environment_ids[]=${env_id}" -f state=approved -f comment="$note"
}
```

**1. No bootstrap re-apply. Confirm the live deploy role (read-only)**

```bash
aws iam get-role --role-name sis-dev-gha-deploy --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' \
  | sed -E 's/[0-9]{12}/<acct>/g'
# expect: sub ...:environment:dev, ref refs/heads/main, workflow app-deploy, repository_id, repository_owner_id, aud
aws iam get-role-policy --role-name sis-dev-gha-deploy --policy-name deploy --query 'PolicyDocument.Statement[].Sid'
# expect: EcrAuth EcrPushOneRepo RegisterTaskDef TagRegisteredTaskDef DescribeTaskDef DescribeOneService UpdateOneService PassTaskRoles
```

**2. Environment secret `AWS_DEPLOY_ROLE_ARN` (E25)**

```bash
terraform -chdir=infra/terraform/bootstrap init -backend-config="bucket=${BUCKET}"
terraform -chdir=infra/terraform/bootstrap output -raw deploy_role_arn | gh secret set AWS_DEPLOY_ROLE_ARN --env dev --repo "$REPO"
gh variable delete AWS_DEPLOY_ROLE_ARN --env dev --repo "$REPO" 2>/dev/null || true   # in case Phase 1 created it as a variable
gh secret list --env dev --repo "$REPO"     # AWS_APPLY_ROLE_ARN, AWS_DEPLOY_ROLE_ARN
gh secret list --repo "$REPO"               # AWS_PLAN_ROLE_ARN_DEV, AWS_ACCOUNT_ID_DEV
```

**3. Read PR 1 (the orchestrator opens it)**

```bash
gh pr checks <PR1> --repo "$REPO" --watch
# app-ci: build-test-scan; terraform-iac: checks, plan, plan-role-guardrails, comment; repo-guard: guard. All green.
gh pr view <PR1> --repo "$REPO" --comments | grep -A60 'terraform-iac:plan:dev'
# The stack is torn down: expect a full create (about 30 to add, 0 to change, 0 to destroy)
RUN_ID="$(gh run list --repo "$REPO" --workflow app-ci.yml --branch phase-4-app-pipeline --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "$RUN_ID" --repo "$REPO" --log | grep -E 'trivy_0\.76\.1_Linux-64bit\.tar\.gz matches|hadolint_2\.15\.1'
```

**4. Merge PR 1, then approve in order: infra, secret, deploy**

```bash
gh pr merge <PR1> --repo "$REPO" --squash
sleep 20
IAC_RUN="$(gh run list --repo "$REPO" --workflow terraform-iac.yml --event push --limit 1 --json databaseId --jq '.[0].databaseId')"
DEPLOY_RUN="$(gh run list --repo "$REPO" --workflow app-deploy.yml --event push --limit 1 --json databaseId --jq '.[0].databaseId')"

approve "$IAC_RUN" "phase 4: re-create dev stack"
gh run watch "$IAC_RUN" --repo "$REPO" --exit-status

APP_API_KEY_VALUE="$(openssl rand -hex 24)"     # keep a copy in your Keychain (kc) for /admin tests
aws secretsmanager put-secret-value --secret-id sis/dev/app-api-key \
  --secret-string "$APP_API_KEY_VALUE" --query VersionId --output text
unset APP_API_KEY_VALUE
# Do NOT force a new deployment: the Terraform revision is a non-serving placeholder (F2).

approve "$DEPLOY_RUN" "phase 4: first app deploy"
gh run watch "$DEPLOY_RUN" --repo "$REPO" --exit-status
# If it failed with "dev stack is not up" because it was approved too early:
#   gh run rerun "$DEPLOY_RUN" --repo "$REPO" --failed
gh run view "$DEPLOY_RUN" --repo "$REPO" --log | grep -c '<DEV_ACCOUNT_ID>'          # expect 0
gh run view "$DEPLOY_RUN" --repo "$REPO" --log | grep 'Denied as designed (N4)'     # deploy role cannot read the secret
```

**5. Verify the app and the digest**

```bash
git fetch origin && SHA="$(git rev-parse origin/main)"
ALB="$(aws elbv2 describe-load-balancers --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"
curl -fsS "http://${ALB}/health"; echo                                  # {"status": "ok"}
curl -fsS "http://${ALB}/version"; echo                                 # env dev, git_sha = $SHA, image_digest sha256:...
curl -fsS "http://${ALB}/" | grep -Eo 'APP_ENV: dev|GIT_SHA: [0-9a-f]{40}|secret_loaded: (yes|no)'   # dev, $SHA, yes
curl -s -o /dev/null -w '%{http_code}\n' "http://${ALB}/admin"          # 401

TD="$(aws ecs describe-services --cluster sis-dev-cluster --services sis-dev-app --query 'services[0].taskDefinition' --output text)"
aws ecs describe-task-definition --task-definition "$TD" --query 'taskDefinition.containerDefinitions[0].[image,command]' --output text \
  | sed -E 's/[0-9]{12}/<acct>/g'
# expect: <acct>.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@sha256:<64 hex>   None   (a digest, not a tag; no command)
aws ecr describe-images --repository-name sis-dev-app --image-ids imageTag="$SHA" \
  --query 'imageDetails[0].[imageDigest,imageManifestMediaType]' --output text
TASK="$(aws ecs list-tasks --cluster sis-dev-cluster --service-name sis-dev-app --desired-status RUNNING --query 'taskArns[0]' --output text)"
aws ecs describe-tasks --cluster sis-dev-cluster --tasks "$TASK" --query 'tasks[0].containers[0].imageDigest' --output text
# The task definition digest, the ECR digest, the running task digest and /version image_digest are all equal.
aws ecs describe-services --cluster sis-dev-cluster --services sis-dev-app \
  --query 'services[0].deployments[].[status,rolloutState]' --output text     # PRIMARY COMPLETED
```

**6. The Phase 4 checkpoint proper: PR 2 (one app line, opened by the orchestrator)**

```bash
gh pr checks <PR2> --repo "$REPO" --watch          # app-ci green; terraform-iac does not run
gh pr merge <PR2> --repo "$REPO" --squash
sleep 20
DEPLOY_RUN="$(gh run list --repo "$REPO" --workflow app-deploy.yml --event push --limit 1 --json databaseId --jq '.[0].databaseId')"
approve "$DEPLOY_RUN" "phase 4 checkpoint"
gh run watch "$DEPLOY_RUN" --repo "$REPO" --exit-status
git fetch origin && curl -fsS "http://${ALB}/version"; echo    # git_sha = new origin/main; open / in a browser: new colour, the changed line
```

Then repeat the digest checks from step 5.

**7. Negative tests**

```bash
ACCT=<DEV_ACCOUNT_ID>
DEPLOY_ROLE_ARN="arn:aws:iam::${ACCT}:role/sis-dev-gha-deploy"
E="arn:aws:ecs:ap-southeast-1:${ACCT}"
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id sis/dev/app-api-key --query ARN --output text)"
sim() { aws iam simulate-principal-policy --policy-source-arn "$DEPLOY_ROLE_ARN" "$@" \
          --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text; }
CPU_OK=("ContextKeyName=ecs:task-cpu,ContextKeyValues=256,ContextKeyType=numeric" "ContextKeyName=ecs:task-memory,ContextKeyValues=512,ContextKeyType=numeric")
CPU_BIG=("ContextKeyName=ecs:task-cpu,ContextKeyValues=1024,ContextKeyType=numeric" "ContextKeyName=ecs:task-memory,ContextKeyValues=2048,ContextKeyType=numeric")

sim --action-names secretsmanager:GetSecretValue --resource-arns "$SECRET_ARN"                               # explicitDeny
sim --action-names ecr:PutImage --resource-arns "arn:aws:ecr:ap-southeast-1:${ACCT}:repository/sis-dev-other" # implicitDeny
sim --action-names ecs:RegisterTaskDefinition --resource-arns "${E}:task-definition/sis-dev-app:1" --context-entries "${CPU_OK[@]}"     # allowed (control)
sim --action-names ecs:RegisterTaskDefinition --resource-arns "${E}:task-definition/sis-dev-other:1" --context-entries "${CPU_OK[@]}"   # implicitDeny
sim --action-names ecs:RegisterTaskDefinition --resource-arns "${E}:task-definition/sis-dev-app:1" --context-entries "${CPU_BIG[@]}"    # implicitDeny
sim --action-names ecs:UpdateService --resource-arns "${E}:service/sis-dev-cluster/sis-dev-app" \
  --context-entries "ContextKeyName=ecs:task-definition,ContextKeyValues=${E}:task-definition/sis-dev-other:1,ContextKeyType=string"   # implicitDeny
sim --action-names ecs:UpdateService --resource-arns "${E}:service/sis-dev-cluster/sis-dev-other" \
  --context-entries "ContextKeyName=ecs:task-definition,ContextKeyValues=${E}:task-definition/sis-dev-app:1,ContextKeyType=string"     # implicitDeny
sim --action-names iam:PassRole --resource-arns "arn:aws:iam::${ACCT}:role/sis-dev-gha-apply"                # implicitDeny

# A branch cannot deploy. Layers: job if (main only), the dev branch policy (main only), and the IAM ref pin.
git push origin origin/main:refs/heads/neg-deploy-test
gh workflow run app-deploy.yml --repo "$REPO" --ref neg-deploy-test
sleep 15
NEG_RUN="$(gh run list --repo "$REPO" --workflow app-deploy.yml --branch neg-deploy-test --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "$NEG_RUN" --repo "$REPO"        # expect: deploy job skipped, no approval prompt, no AWS step ran
git push origin --delete neg-deploy-test
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 10 --output json \
  | jq -r '.Events[].CloudTrailEvent | fromjson | [.eventTime, (.errorCode // "OK"), .requestParameters.roleSessionName] | @tsv'
# expect: no gha-deploy-* session at the time of NEG_RUN; gha-deploy-* sessions only from the approved main runs
```

Also confirm by reading the files that PRs never get the deploy role:

```bash
grep -n 'id-token\|secrets\.' .github/workflows/app-ci.yml || echo "app-ci has no id-token and no secrets"
```

**8. harden-runner exposure check (Q1)**

Open the insights link from the `deploy` job of the last app-deploy run, and from the `apply` job of the last `terraform-iac` push run, in a logged-out browser. Search the Network Events for `<DEV_ACCOUNT_ID>`. Report the result so Q1 can be closed.

**9. Teardown (until Phase 5), same as ADR 0004 B8**

```bash
export TF_VAR_aws_account_id=<DEV_ACCOUNT_ID>
terraform -chdir=infra/terraform/envs/dev init -backend-config="bucket=${BUCKET}"
terraform -chdir=infra/terraform/envs/dev plan -destroy -out=destroy.tfplan
terraform -chdir=infra/terraform/envs/dev apply destroy.tfplan
rm infra/terraform/envs/dev/destroy.tfplan
# ECR images go with the repository (force_delete). Deploy-registered task definition revisions stay registered (no cost).
```

Re-create next session:

1. `gh workflow run terraform-iac.yml --repo "$REPO" --ref main`, then approve.
2. Set the secret value as in step 4.
3. `gh workflow run app-deploy.yml --repo "$REPO" --ref main`, then approve.
4. Run step 5.

## Sources

- Trivy releases (v0.76.1, 2026-10-21): https://github.com/aquasecurity/trivy/releases
- Trivy v0.76.1 checksums: https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_checksums.txt
- Trivy advisory GHSA-69fq-xp46-6x23: https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23
- Trivy advisories list: https://github.com/aquasecurity/trivy/security/advisories
- Trivy signature verification (`cosign verify-blob`, `.sigstore.json`): https://trivy.dev/docs/dev/getting-started/signature-verification/
- Trivy `image` CLI reference (db repositories, `--input`, `--ignore-unfixed`, `--disable-telemetry`): https://trivy.dev/docs/latest/guide/references/configuration/cli/trivy_image/
- Trivy filtering (`.trivyignore` `exp:`): https://trivy.dev/docs/latest/guide/configuration/filtering/
- hadolint latest release: https://api.github.com/repos/hadolint/hadolint/releases/latest
- hadolint v2.15.1 checksums: https://github.com/hadolint/hadolint/releases/download/v2.15.1/checksums.sha256
- amazon-ecs-render-task-definition tags, tag object, action.yml, source, releases:
  - https://api.github.com/repos/aws-actions/amazon-ecs-render-task-definition/tags?per_page=5
  - https://api.github.com/repos/aws-actions/amazon-ecs-render-task-definition/git/tags/731946636f59740045709b55a095be66765facea
  - https://raw.githubusercontent.com/aws-actions/amazon-ecs-render-task-definition/8d79160660ad39c402a16e5fc7cd2a32e8f7d6b7/action.yml
  - https://raw.githubusercontent.com/aws-actions/amazon-ecs-render-task-definition/8d79160660ad39c402a16e5fc7cd2a32e8f7d6b7/index.js
  - https://github.com/aws-actions/amazon-ecs-render-task-definition/releases
- amazon-ecs-deploy-task-definition tags, tag object, action.yml, source, releases:
  - https://api.github.com/repos/aws-actions/amazon-ecs-deploy-task-definition/tags?per_page=5
  - https://api.github.com/repos/aws-actions/amazon-ecs-deploy-task-definition/git/tags/ae89e14ac6188020feb2b19228b7149a7bc9cf0b
  - https://raw.githubusercontent.com/aws-actions/amazon-ecs-deploy-task-definition/a00d4d57ac0de1a99b39fe469f3d898d38717c2b/action.yml
  - https://raw.githubusercontent.com/aws-actions/amazon-ecs-deploy-task-definition/a00d4d57ac0de1a99b39fe469f3d898d38717c2b/index.js
  - https://github.com/aws-actions/amazon-ecs-deploy-task-definition/releases
- amazon-ecr-login release, tag object, action.yml:
  - https://api.github.com/repos/aws-actions/amazon-ecr-login/releases/latest
  - https://api.github.com/repos/aws-actions/amazon-ecr-login/git/tags/aded0d722166a37980e030aa969dda0bfe6b6947
  - https://raw.githubusercontent.com/aws-actions/amazon-ecr-login/03f1aad4c6c7ffd436567f42f9384779290529bd/action.yml
- docker/build-push-action v7.4.0: https://api.github.com/repos/docker/build-push-action/releases/latest, https://api.github.com/repos/docker/build-push-action/git/ref/tags/v7.4.0
- docker/setup-buildx-action v4.4.1: https://api.github.com/repos/docker/setup-buildx-action/releases/latest, https://api.github.com/repos/docker/setup-buildx-action/git/ref/tags/v4.4.1
- harden-runner latest and action.yml at pin: https://api.github.com/repos/step-security/harden-runner/releases/latest, https://raw.githubusercontent.com/step-security/harden-runner/dc2769abcc0fcfbadfc1df54081c1608579ef6b2/action.yml
- configure-aws-credentials latest: https://api.github.com/repos/aws-actions/configure-aws-credentials/releases/latest
- actions/checkout latest: https://api.github.com/repos/actions/checkout/releases/latest
- Ubuntu 24.04 runner image (Docker, Buildx, AWS CLI, jq): https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
- ECS task metadata v4 on Fargate: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v4-fargate.html
- ECS task metadata v4 response (`ImageID` = manifest digest): https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v4-fargate-response.html
- ECS `Deployment` (rolloutState): https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Deployment.html
- ECS `RegisterTaskDefinition`: https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_RegisterTaskDefinition.html
- ECS deployment circuit breaker: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html
- AWS CLI `ecs wait services-stable`: https://docs.aws.amazon.com/cli/latest/reference/ecs/wait/services-stable.html
- ECR private registry authentication: https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html
- ECR tag immutability: https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html
- GitHub artifact attestations: https://docs.github.com/en/actions/concepts/security/artifact-attestations
- GitHub concurrency: https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
- GitHub deployments and environments: https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
- Docker run reference (PID 1 signals, `--read-only`, `--tmpfs`): https://docs.docker.com/reference/cli/docker/container/run/
- Seen only in search results (not opened), for Q1: https://docs.stepsecurity.io/resources/whos-using-harden-runner, https://docs.stepsecurity.io/harden-runner/workflow-runs

## Build briefs

### backend-dev (owns `app/**`)

**Goal:** F20. Keep `board.py` around 100 lines and stdlib only. Do not edit `infra/**`, `.github/**`, `scripts/**`, `Makefile`, `README.md` or `docs/**`.

**Files:**

- `app/src/board.py`: SIGTERM handler; never read or show the metadata `Image` field.
- `app/tests/test_app.py`: the new tests below.
- `app/Dockerfile`:
  - both `FROM` lines become `public.ecr.aws/docker/library/python:3.13-slim@sha256:<index digest>` (Q3);
  - OCI labels `org.opencontainers.image.revision` (from `GIT_SHA`) and `org.opencontainers.image.source` in the runtime stage;
  - keep `USER 10001:10001`, `HEALTHCHECK`, and `GIT_SHA` as the only build argument.
- `app/.trivyignore`: only if needed, each entry with a comment and `exp:YYYY-MM-DD`.

**Verify before pinning:** run `docker buildx imagetools inspect public.ecr.aws/docker/library/python:3.13-slim` and record the index digest. Confirm it lists `linux/amd64`. If it differs from the Docker Hub digest, report both; do not guess.

**Tests first (red, then green):**

1. `test_sigterm_stops_server`:
   - start `python src/board.py` in a subprocess with `PORT` set to a free port (bind port 0, read it, close) and `PYTHONUNBUFFERED=1`;
   - poll `/health` until it returns 200;
   - send `SIGTERM`;
   - assert the process exits within 5 s with return code 0.
2. `test_image_uri_never_shown`:
   - mock the metadata response as `{"Image": "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@sha256:aa...", "ImageID": "sha256:bb..."}`;
   - assert `/` and `/version` contain `sha256:bb...` and contain neither `dkr.ecr` nor `123456789012`.
3. Keep the existing tests green (secret never in responses, 401 cases, `BREAK=true`).

**Checks that define done:**

- `make test` (unittest), `pre-commit run ruff-check --all-files`, `pre-commit run ruff-format --all-files`, `pre-commit run mypy --all-files`, `hadolint app/Dockerfile`: all clean.
- `docker build --build-arg GIT_SHA=$(git rev-parse HEAD) -t sis-app:local app` succeeds (the tests run inside).
- `docker run --rm -d --name sis-smoke --read-only --tmpfs /tmp:rw,mode=0755,uid=0,gid=0 --user 10001:10001 --cap-drop ALL --security-opt no-new-privileges -e APP_ENV=ci -e APP_API_KEY=fake -p 8080:8080 sis-app:local`:
  - `curl localhost:8080/health` returns 200;
  - `/` shows `secret_loaded: yes`;
  - `time docker stop sis-smoke` takes under 3 s.
- `trivy image --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 sis-app:local` (mise 0.76.1) passes. If it fails, bump the base digest; never add an ignore without a reason and an expiry.
- `make up` still works locally.
- Commit: `feat(app): graceful sigterm, oci labels and ecr public base image`.

### devops-engineer (owns `infra/**`, `.github/**`, `scripts/**`, `.pre-commit-config.yaml`, `Makefile`)

**Goal:** F2 to F19 and F22. **No bootstrap change. Do not edit `terraform-iac.yml`, `oidc-smoke-test.yml`, `README.md`, `docs/**` or `app/**`.** Never run `terraform apply`, `import` or `state`, any `gh secret` / `gh variable` / `gh workflow run`, or a merge.

**Verify pins before use (NFR-3).** If anything differs from this ADR, stop and report; do not substitute.

```bash
git ls-remote https://github.com/step-security/harden-runner 'refs/tags/v2.22.2*'           # dc2769abcc0fcfbadfc1df54081c1608579ef6b2
git ls-remote https://github.com/actions/checkout 'refs/tags/v7.0.1*'                      # 3d3c42e5aac5ba805825da76410c181273ba90b1
git ls-remote https://github.com/aws-actions/configure-aws-credentials 'refs/tags/v6.3.0*' # e1253824e5c10ff9df46874f81ed3ec929e19cfd
curl -fsSL https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_checksums.txt | grep 'Linux-64bit.tar.gz$'
# c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0
curl -fsSL https://github.com/hadolint/hadolint/releases/download/v2.15.1/checksums.sha256 | grep 'hadolint-linux-x86_64$'
# c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
# Once, if cosign is available (for example: mise x cosign@latest -- cosign ...):
cosign verify-blob trivy_0.76.1_Linux-64bit.tar.gz --bundle trivy_0.76.1_Linux-64bit.tar.gz.sigstore.json \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v0.76.1'
# Verified OK. If cosign is unavailable, say so in the hand-back.
```

**Files:**

- `.github/workflows/app-ci.yml` (F13) and `.github/workflows/app-deploy.yml` (F14 to F18).
- `scripts/install-ci-tools.sh`: tool arguments, default `terraform tflint`; trivy (tar.gz, extract `trivy`) and hadolint (raw binary saved as `hadolint_<v>_linux_x86_64`, installed as `hadolint`).
- `scripts/ci-tools.sha256`: add the two lines.
- New scripts:
  - `scripts/check-aws-config.sh <role-name>`;
  - `scripts/app-smoke.sh <image> <git sha>`;
  - `scripts/scan-image.sh <image> <out dir>`;
  - `scripts/render-task-def.sh <describe.json> <image@digest> <git sha>` (prints the register JSON to stdout);
  - `scripts/ecs-wait-deployment.sh <cluster> <service> <td arn> [timeout s]`, plus `--evaluate <td arn>` reading JSON on stdin.
- `scripts/ci-selftest.sh`: fixtures for the render and evaluate scripts.
- `infra/terraform/envs/dev/{terraform.tfvars,variables.tf,main.tf,README.md,tests/}` and `infra/terraform/modules/app-ecs/{variables.tf,ecs.tf,README.md,tests/}`: remove `container_command` (F2). Update the placeholder comment ("never serves; app-deploy sets the image"). Regenerate terraform-docs.
- `Makefile`: `image`, `smoke`, `scan` targets (one line each, `## description`, not in `check`).

All scripts follow `lib.sh`, bash 3.2 and shellcheck rules. Nothing prints an ARN, the image URI or raw describe JSON.

**Tests first (red, then green):**

1. **`render-task-def.sh`** (in `ci-selftest.sh`, with fixtures built at run time using account `123456789012`). A good Terraform-shaped describe JSON (one container `app`, task cpu `"256"` and memory `"512"`, the exec and task role ARNs, `/tmp` volume, secret ARN `...:secret:sis/dev/app-api-key-AbC123`, plus every read-only key including `deleteRequestedAt`) renders to:
   - exactly the request keys;
   - `image` = the given digest URI;
   - no read-only keys;
   - tags `Project`, `Env`, `ManagedBy=app-deploy`, `GitSha`;
   - secrets, roles, volumes and cpu/memory unchanged.

   Each of these must fail with a named message:
   - `command` present;
   - two containers;
   - container not named `app`;
   - unknown top-level key `fooBar`;
   - image argument with `:tag` instead of a digest;
   - image from another repository;
   - missing task-level `cpu`;
   - `memory` = `"2048"`;
   - wrong exec role name;
   - secret ARN for another name.
2. **`ecs-wait-deployment.sh --evaluate`:**
   - our deployment `COMPLETED` and PRIMARY gives success;
   - `IN_PROGRESS` gives continue;
   - `FAILED` gives failure with the reason printed and 12-digit runs redacted;
   - our deployment absent with PRIMARY on another revision gives "rolled back";
   - an empty `services` or a `MISSING` failure gives "stack not up".
3. **`install-ci-tools.sh`** on scratch copies (the existing `CI_TOOLS_*` overrides):
   - a corrupted trivy hash fails "checksum mismatch";
   - a bumped trivy version in a scratch `mise.toml` fails "no checksum";
   - an unknown tool name fails;
   - no tool arguments installs only terraform and tflint.
4. **`app-smoke.sh`:**
   - against a throwaway image built in the scratchpad whose CMD writes to `/tmp` before serving, it fails;
   - against `sis-app:local` from backend-dev's branch, or from `main` plus F20 once merged locally, it passes, including the stop-time check.
5. **Terraform:**
   - the module test asserts the container JSON has no `command` key and that `container_command` is no longer an input;
   - the `envs/dev` tests still plan under mocks with the committed tfvars.
6. **Workflows** (in the scratchpad):
   - a bad copy of each workflow (tag-pinned `uses:`, workflow-level `id-token: write`, `${{ github.event.pull_request.head.ref }}` in `run:`, a `pull_request_target` trigger) must fail `actionlint` and `uvx zizmor@1.31.1 --offline`;
   - then write the real ones until both are clean.

**Checks that define done:**

- `make check` green (pre-commit including zizmor and the account-ID guard, hadolint, shellcheck, `ci-selftest.sh`, actionlint, unittest, tf-check).
- `pre-commit run zizmor --all-files`: no findings, no ignore comments. `scripts/check-workflow-triggers.sh` passes.
- Grep checks on **`app-ci.yml`**:
  - `name: app-ci`;
  - top-level `permissions: {}`;
  - the only job permission is `contents: read`;
  - no `id-token`, no `secrets.`, no `environment:`, no `docker login`, no `docker push`, no `upload-artifact`, no `trivy-action`, no `setup-trivy`.
- Grep checks on **`app-deploy.yml`**:
  - `name: app-deploy`;
  - triggers exactly `push` (main, F14 paths) and `workflow_dispatch`;
  - `environment: dev` and `id-token: write` only on `deploy`;
  - `if: github.ref == 'refs/heads/main'`;
  - `concurrency` group `app-deploy-dev`, `cancel-in-progress: false`;
  - the `configure-aws-credentials` step comes after the build, smoke and scan steps, and none of those three has `secrets.` in its `env:`;
  - `mask-aws-account-id: true`;
  - no `aws-actions/amazon-ecr-login`, no `amazon-ecs-*`, no `docker/` actions;
  - `update-service` always has `--task-definition`;
  - no `--force-new-deployment`;
  - no `services-stable`.
- Both files:
  - harden-runner is step 1 with `egress-policy: audit`;
  - `runs-on: ubuntu-24.04`;
  - `timeout-minutes` on every job;
  - `persist-credentials: false`;
  - every `uses:` is `owner/repo@<40 hex> # vX.Y.Z`;
  - no `${{` inside `run:`.
- `terraform fmt -check -recursive infra/terraform`, `make tf-check`, `tflint --recursive`: clean.
- `git status` shows no `*.tfvars` other than `envs/dev/terraform.tfvars`, no state, no plan files, no scratch files. No account ID anywhere.
- Commits (follow `pr-conventions`):
  - `infra(envs-dev): drop the placeholder container command`
  - `ci(workflows): app ci with checksum-pinned trivy and hadolint`
  - `ci(workflows): app deploy by digest with rollout verification`
  - `chore(scripts): ci tool selection, smoke, scan, render and wait helpers`
- Hand back the checkpoint commands from this ADR unchanged.
