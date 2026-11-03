# A shell only (FR-8): the value is set by hand with put-secret-value and never enters Terraform or state.
# This module must not contain a secret version resource (tf/policy.sh rule 1). The app reads the value itself at
# first use with the execution role (ADR 0012 L5).
resource "aws_secretsmanager_secret" "app" {
  name                    = local.names.secret
  description             = "App API key. Value is set outside Terraform."
  recovery_window_in_days = var.secret_recovery_window_days
}
