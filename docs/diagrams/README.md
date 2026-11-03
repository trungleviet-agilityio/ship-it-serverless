# Diagrams

Architecture diagrams drawn with `/sis-team:diagram <topic>` from the Terraform, workflows and ADRs. Each has
an editable `.drawio` source and a `.drawio.png` export with the XML embedded, so either file opens in draw.io.
Grey dotted parts are planned and not in code yet.

These diagrams come from the `ship-it-safely` template (prefix `sis`, ECS era). The bootstrap and infra pipeline
diagrams still match the shape of this lab except for the names and the env stack, which is now `modules/app-lambda`
(ADR 0012). The ECS runtime, app pipeline and overview diagrams were removed; the README and
[`docs/requirements.md`](../requirements.md) carry the Lambda architecture as text until `/sis-team:diagram lambda`
redraws them.

| Diagram | Shows | Based on | Date |
|---|---|---|---|
| [bootstrap](bootstrap.drawio.png) | State bucket, OIDC provider, plan/apply/deploy roles and their trust (including `job_workflow_ref` and the region pin), guardrail and boundary policies, budget, and the envs/dev resources the roles are scoped to | `e43b2f9` | 2026-10-27 |
| [bootstrap: security alert](bootstrap-security-alert.drawio.png) | Page 2 of `bootstrap.drawio`: STS, the CloudTrail trail and its bucket, the EventBridge rule, the SNS topic and email, guardrail G6 | `e43b2f9` | 2026-10-27 |
| [ci-cd: infra pipeline](ci-cd.drawio.png) | Page 1 of `ci-cd.drawio`: `terraform-iac` (checks, plan with the plan role, plan-role negative tests, sticky comment, approved apply) and `terraform-destroy` (typed confirm, approved destroy), the state bucket and the envs/dev stack | `d39b84c` | 2026-10-27 |

Regenerate or extend one with `/sis-team:diagram <topic>`; it validates the file, exports it and checks the PNG.
