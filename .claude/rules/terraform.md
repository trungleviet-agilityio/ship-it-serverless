---
paths:
  - "infra/terraform/**"
---

# Terraform

Read `docs/reference/standards/terraform.md` before editing. Lab-specific points it builds on:

- Terraform owns the function's shape; the deploy owns the image, `IMAGE_DIGEST`, the description and the alias
  version and weights. Keep them in `ignore_changes` and assert the list in tftest (ADR 0012 L3).
- ECR lives in `bootstrap`, one repository per account (L4). Bootstrap changes need an admin re-apply.
- IAM: `iam:PassRole` only on the execution role with `iam:PassedToService = lambda.amazonaws.com`; exact
  `aws:sourceArn` values; `lambda:AddPermission` conditioned on `lambda:Principal`; the secret read only with
  `lambda:SourceFunctionArn` (L9). Assert every statement in tftest.
- `mock_provider` tests cannot find a missing IAM read action: add an AccessDenied check to the checkpoint.
- No account IDs in committed files; `*.tfvars.example` only.
