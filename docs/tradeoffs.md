# Trade-offs: Lambda Web Function lab

Every design choice of this lab in one place, with the options that lost and why. The decisions themselves are
locked in [ADR 0012](adr/0012-lambda-web-function-architecture.md); this file is the study guide. Facts marked
(S) or (C) in the ADR are second-hand or still to be confirmed on live AWS; prices are US reference rates.

## How to read this

Each section answers one question. The chosen option is in bold. "Pros" and "Cons" are about this lab (one small
stdlib web app, two AWS accounts, a 20 USD/month budget, near-zero traffic), not about every workload. The last
column, "Would change my mind", says what would flip the decision on a real product.

## 1. Event-style functions vs a web function

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| Event-style functions (one handler per route or event) | Fine-grained IAM and scaling per route; smallest packages; the classic tutorial shape | Routing lives in API Gateway config; many functions to deploy and version; local run needs an emulator | Many routes with very different permissions or traffic |
| **Web function ("Lambdalith"): one function runs a normal web app** | Any framework or plain HTTP server works; one artifact; local run is `docker compose up`; moving to Fargate later is a deploy change, not a rewrite | One IAM role for every route; one cold start profile; a bug in one route ships with all of them | A route that needs different permissions or memory |

## 2. How the web app gets onto Lambda (ADR L1)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **Container image + AWS Lambda Web Adapter (LWA), image in ECR, deployed by digest** | App code unchanged; same image locally, in CI and in Lambda; base image digest, Trivy gate and Dependabot keep working; promote by digest unchanged | No Lambda code signing for images; one more binary (LWA) to pin and watch; LWA readiness wait adds to cold start | A need for code signing, or cold starts that matter (then zip + SnapStart) |
| Native handler, zip package | Smallest cold start; SnapStart and AWS Signer code signing | Rewrite routing as `handler(event, context)`; local run differs; new S3 artifact pipeline and cross-account bucket | Latency-critical API with spiky traffic |
| AWS base image + runtime interface client | AWS patches the base | Still a handler rewrite; bigger image; same code-signing gap | Team already standardized on AWS base images |
| Zip + LWA as a layer | No container registry | Layers are per-region resources to pin and promote; lose the image story | No ECR allowed |

## 3. Front door (ADR L2)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **API Gateway HTTP API** | Stage throttling is a hard cost cap in any account; JSON access logs; custom domains; the classic serverless entry point; simple `lambda:InvokeFunction` permission with `SourceArn` | About 1 USD per million requests after the free tier; about 30 s integration timeout; no AWS WAF; four more resources | Need WAF or IP allowlists (REST API or CloudFront), or long requests (Function URL) |
| Lambda Function URL | No extra cost; fewest resources; timeout up to 15 minutes; response streaming | No throttling and no access log, so a public URL has no cost ceiling when reserved concurrency is unavailable; the auth policy changed in October 2025 and the docs disagree | A private tool behind `AWS_IAM` auth, or a CloudFront + OAC front |
| API Gateway REST API | WAF, resource policies with IP conditions, usage plans, caching | About 3.5 times the HTTP API price; more configuration | Public API that needs WAF or API keys |
| ALB with a Lambda target | WAF, security group CIDR allowlists, path routing next to containers | Hourly charge plus LCU, about the whole budget if left up; brings back the VPC | Lambda behind an existing ALB that already pays its hours |
| CloudFront in front of a Function URL (OAC) | Edge caching, WAF, custom domain, cheap | Another service, OAC signing rules for request bodies | Global users or WAF without REST API |

## 4. Who owns what: Terraform vs the deploy (ADR L3)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **Terraform owns the shape; the deploy owns the image, the `IMAGE_DIGEST` value and the alias** | Same split as the ECS template (ADR 0005 F2); a deploy needs no Terraform run; PR plans still show shape changes | `ignore_changes` on four attributes; the first `terraform apply` needs an image already pushed | Teams that want one tool (SAM or CDK deploy everything) |
| Terraform owns everything, deploy = `terraform apply -var image=...` | One source of truth | The apply role becomes the deploy role; every release needs a state lock and a plan | Small teams with no separate deploy path |
| SAM or CDK for the function | `AutoPublishAlias` and CodeDeploy wiring for free | A second IaC tool next to Terraform | Starting from scratch without Terraform |

## 5. Where the ECR repository lives (ADR L4, owner Q2)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **Bootstrap (one repository per account)** | A function can only be created from an existing private image; env destroy never deletes images that versions use; promote and rollback work with the dev stack down | Bootstrap grows and needs an admin re-apply | A shared registry account for many apps |
| Env stack (template layout) | No bootstrap change | Chicken and egg at create (no public placeholder allowed); destroy deletes images | Never for Lambda images |
| Separate shared root | Clean ownership | A third state and apply path for one resource | Many repositories per account |
| One central registry account, cross-account pulls | One place for scanning and retention | Cross-account repository policies for every function; promotion by policy, not by copy | An organization with a platform team |

## 6. Secrets (ADR L5, owner Q1)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| Parameters and Secrets Lambda Extension | No app code; built-in cache and TTL | Distributed as a layer only: copying it into an image needs AWS credentials in the build job (the build is credential-free on purpose) and has no public digest to pin | AWS publishes it as a public image with a digest |
| **App reads Secrets Manager with stdlib SigV4** | Keeps the app stdlib-only; no extra binary; one HTTPS call per cold start; tested offline against AWS's published SigV4 example | About 100 lines of signing code to own | A framework app that already depends on boto3 |
| App uses boto3 | Battle-tested client | Breaks the stdlib-only rule; image grows by megabytes | The app already has dependencies |
| Value injected into an env var by Terraform or the deploy | Simplest app | Value lands in state or in `GetFunctionConfiguration`; a CI role would need `GetSecretValue`; breaks FR-8 | Never for real secrets |
| SSM Parameter Store SecureString | Free standard tier | Same delivery problem as Secrets Manager; no rotation | Cost matters more than rotation |

## 7. Proving which image runs (ADR L6)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **Deploy sets `IMAGE_DIGEST` before `PublishVersion`** | Each version carries its own digest, so an alias flip shows the right value; `/version` keeps the app contract | Deploy role needs `UpdateFunctionConfiguration` (no `PassRole`, so it cannot swap the role) | A stricter split where the deploy can only touch code |
| App calls `lambda:GetFunction` on itself | No config write by the deploy | Execution role gets Lambda read; one more signed call at cold start | Already signing other calls |
| Bake the digest into the image | Nothing at deploy | Impossible: the digest is the hash of the image itself | Never |
| Drop the digest from `/version` | Simplest | Loses the end-to-end proof the lab is built on | Only the pipeline needs the proof |

## 8. Release strategy and canary (ADR L7)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **Pipeline: publish, smoke-invoke the version, then all-at-once or alias-weighted canary** | No extra service; a bad version never gets traffic; canary is native alias routing (`AdditionalVersionWeights`); rollback is one `UpdateAlias` | The pipeline holds the logic; lab traffic is synthetic, so the canary judges probes and `Errors` only | Real traffic with SLOs |
| CodeDeploy traffic shifting (`Canary10Percent5Minutes`, `Linear*`) | Managed canary, alarm-based auto revert, hooks | CodeDeploy app, group, service role, `PassRole`, hook functions; a canary over near-zero traffic proves nothing | Production traffic and alarms worth trusting |
| All at once only | Simplest | Nothing to learn about canaries | Internal tools |
| Two functions (blue and green) behind the API | Full isolation | Double cost and config; aliases already solve it | Different IAM per color |

Why the smoke invoke matters: Lambda has no health check like an ALB target group. LWA waits for `/health` to
answer before the first request, so a version whose `/health` fails never serves a request. Invoking the
**version** (not the alias) proves that before any user sees it.

## 9. Rollback (ADR L8)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **Move `live` to an existing version when one has the requested digest, else publish from the digest already in ECR** | Seconds, no rebuild; same approvals as promote; the same path for dev and prod | Needs the old image to still exist (kept: 20 images, 10 versions) | Images deleted by policy |
| `git revert` and redeploy | Audit trail in git | Minutes; rebuilds the image (a new digest) | Dev, where it stays the normal path |
| Keep the previous version number in the alias description and flip back | Very fast | Only one step back; state outside git | Emergency button only |

## 10. IAM shape (ADR L9)

| Question | Choice | Trade-off |
|---|---|---|
| Deploy role and `iam:PassRole` | **None, plus an explicit Deny** | The deploy cannot change the execution role; Terraform must create and update the function |
| Pruning old versions | **`DeleteFunction` allowed only on qualified ARNs (`function:<name>:*`)** | The deploy can delete versions but never the function |
| Execution role | **Custom, two statements; not `AWSLambdaBasicExecutionRole`** | The managed policy allows `logs:CreateLogGroup` on `*` |
| Permissions boundary | **Kept on every role the apply role creates** | One more policy in bootstrap; caps a compromised apply role |
| ECR repository policy | **`lambda.amazonaws.com` scoped by `aws:sourceArn`; nobody but the admin can edit it** | Lambda cannot auto-add its statement; that is the point |

## 11. Cost ceiling and observability (ADR L10)

| Option | Pros | Cons | Would change my mind |
|---|---|---|---|
| **HTTP API throttling + optional reserved concurrency + three alarms to SNS** | Works in any account; alarms reach an email already confirmed | Throttled clients get 429 | Real users who must not see 429 |
| Reserved concurrency only | One setting | Impossible when the account quota is low (you must leave 100 unreserved) | Accounts with the default 1,000 |
| X-Ray tracing | Request traces | Cost and noise for one route | Several downstream calls |
| CloudWatch Logs Insights dashboards | Rich queries | Not needed for one route | Real traffic |

## 12. Keep ECS beside Lambda? (ADR L11)

| Option | Pros | Cons |
|---|---|---|
| **Remove ECS** | One runtime to learn; no VPC; fewer IAM statements | Comparison lives in `ship-it-safely` history |
| Keep both behind a switch | Side-by-side numbers | Double IAM, tests and deploy paths for a lab |

The image still runs on Fargate unchanged: the LWA extension only starts inside Lambda.

## 13. CPU, environments, prefix, teardown (ADR L12)

| Question | Options | Choice and trade-off |
|---|---|---|
| CPU | `x86_64`; `arm64` | **`x86_64`**: native build on the runner; arm64 is about 20 percent cheaper per GB-second but the bill is inside the free tier and arm needs an arm runner or QEMU |
| Environments | dev only; dev and prod | **dev and prod**: promote by digest across accounts is the core lesson and costs nothing idle |
| Prefix | `sis`; new | **`sls`**: two labs in one account never collide |
| Teardown | destroy after each session; keep up | **Keep dev up, destroy prod after its checkpoint**: no hourly charges any more; the secret costs about 0.40 USD/month |

## 14. Cold starts, in numbers to measure

Not measured yet (no AWS in the authoring session). At the first checkpoint record: the `Init Duration` of the
first `REPORT` log line after a deploy, the same after 30 minutes idle, and `/version` latency through the API.
Expect a few hundred milliseconds to about a second for a slim Python image plus LWA; compare with the ECS task
start time (tens of seconds, but once per deploy).

## 15. What this lab gives up compared with the ECS template

- ALB ingress CIDR allowlist (no WAF or IP filter on an HTTP API).
- ECS circuit breaker semantics (replaced by the smoke invoke and the canary).
- Image code signing (not supported for Lambda images).
- Long requests (HTTP API about 30 s).
- One image runs everywhere, as before, but `/version` digest now depends on the deploy writing `IMAGE_DIGEST`.
