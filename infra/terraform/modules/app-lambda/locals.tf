locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  name       = "${var.prefix}-${var.env}"

  # Name contract with bootstrap `resource_names` (ADR 0002, ADR 0012 L3, L4): the apply and deploy roles, the
  # boundary and the ECR repository policy (LambdaPull aws:sourceArn) are scoped by these exact names.
  names = {
    function         = "${local.name}-app"
    alias            = "live"
    api              = "${local.name}-api"
    app_exec_role    = "${local.name}-app-exec"
    boundary         = "${local.name}-app-boundary"
    ecr_repository   = "${local.name}-app"
    lambda_log_group = "/aws/lambda/${local.name}-app"
    api_log_group    = "/aws/apigateway/${local.name}-api"
    secret           = "${var.prefix}/${var.env}/app-api-key"
    alarm_errors     = "${local.name}-app-errors"
    alarm_throttles  = "${local.name}-app-throttles"
    alarm_api_5xx    = "${local.name}-api-5xx"
  }

  # The boundary is owned by bootstrap (G4 keeps CI roles off it); its ARN is built, never typed in.
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.names.boundary}"

  # The repository is owned by bootstrap (L4). Built from the account, region and DNS suffix, so the module needs no
  # extra ECR read (data "aws_ecr_repository" would also list its tags).
  ecr_repository_url = "${local.account_id}.dkr.ecr.${var.aws_region}.${data.aws_partition.current.dns_suffix}/${local.names.ecr_repository}"

  # The image the function is created from: the newest image in the repository, pinned by digest. Later images
  # come from App Deploy (L3, L7), which Terraform ignores.
  initial_image_digest = data.aws_ecr_image.app.image_digest
  initial_image_uri    = "${local.ecr_repository_url}@${local.initial_image_digest}"

  alarm_actions = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
}
