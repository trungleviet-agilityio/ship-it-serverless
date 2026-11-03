resource "aws_iam_role" "exec" {
  name                 = local.names.exec_role
  assume_role_policy   = data.aws_iam_policy_document.exec_trust.json
  permissions_boundary = local.boundary_arn
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "exec" {
  name   = "exec"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}

# No permission policy: the app makes no AWS calls.
resource "aws_iam_role" "task" {
  name                 = local.names.task_role
  assume_role_policy   = data.aws_iam_policy_document.task_trust.json
  permissions_boundary = local.boundary_arn
  max_session_duration = 3600
}
