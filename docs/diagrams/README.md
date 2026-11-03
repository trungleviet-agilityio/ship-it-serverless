# Diagrams

Architecture diagrams drawn with `/sis-team:diagram <topic>` from the Terraform, workflows and ADRs. Each has
an editable `.drawio` source and a `.drawio.png` export with the XML embedded, so either file opens in draw.io.
Grey dotted parts are planned and not in code yet.

| Diagram | Shows | Based on | Date |
|---|---|---|---|
| [bootstrap](bootstrap.drawio.png) | State bucket, OIDC provider, plan/apply/deploy roles and their trust (including `job_workflow_ref` and the region pin), guardrail and boundary policies, budget, and the envs/dev resources the roles are scoped to | `e43b2f9` | 2026-10-27 |
| [bootstrap: security alert](bootstrap-security-alert.drawio.png) | Page 2 of `bootstrap.drawio`: STS, the CloudTrail trail and its bucket, the EventBridge rule, the SNS topic and email, guardrail G6 | `e43b2f9` | 2026-10-27 |
| [overview](overview.drawio.png) | End to end: the GitHub jobs and the role each assumes over OIDC, the bootstrap stack, the envs/dev stack (ALB, ECS service, ECR), the user request path, and the prod account with digest promotion (planned, Phase 7) | `d39b84c` | 2026-10-27 |
| [ci-cd: infra pipeline](ci-cd.drawio.png) | Page 1 of `ci-cd.drawio`: `terraform-iac` (checks, plan with the plan role, plan-role negative tests, sticky comment, approved apply) and `terraform-destroy` (typed confirm, approved destroy), the state bucket and the envs/dev stack | `d39b84c` | 2026-10-27 |
| [ci-cd: app pipeline](ci-cd-app-pipeline.drawio.png) | Page 2 of `ci-cd.drawio`: `app-ci` on PRs, `app-deploy` split into `build-scan` (no AWS) and the approved `deploy` job, the sha256-checked artifact, then preflight, ECR push, task definition by digest and service update | `d39b84c` | 2026-10-27 |
| [app-ecs](app-ecs.drawio.png) | The envs/dev runtime from `modules/app-ecs`: internet gateway, ALB and Fargate task in the public subnets, the execution role pulling from ECR, injecting the secret and writing logs, security group rules and service settings | `d39b84c` | 2026-10-27 |

Regenerate or extend one with `/sis-team:diagram <topic>`; it validates the file, exports it and checks the PNG.
