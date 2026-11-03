locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region
  name       = "${var.prefix}-${var.env}"

  # State bucket (B8) and the only keys the CI roles may touch (B17, B18).
  bucket_name   = "${local.name}-tfstate-${local.account_id}-${local.region}-an"
  bucket_arn    = "arn:${local.partition}:s3:::${local.bucket_name}"
  state_key     = "envs/${var.env}/terraform.tfstate"
  lock_key      = "${local.state_key}.tflock"
  state_arn     = "${local.bucket_arn}/${local.state_key}"
  lock_arn      = "${local.bucket_arn}/${local.lock_key}"
  bootstrap_arn = "${local.bucket_arn}/bootstrap/*"

  # The S3 backend lists the state key and, for workspaces, the "env:/" prefix. Neither exposes object data.
  state_list_prefixes = [local.state_key, "env:/*"]

  # OIDC (B12). The immutable form carries owner and repo IDs.
  gh_sub_prefix = (
    var.github_immutable_subject
    ? "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
    : "repo:${var.github_owner}/${var.github_repo}"
  )
  oidc_host = "token.actions.githubusercontent.com"

  # Workflow files (ADR 0007 S2, S29): the apply and deploy roles trust the job_workflow_ref claim, which holds
  # the file path and the ref. A `name:` can be copied into any merged file; a path cannot. Phases 3 to 5 must
  # use exactly these files, and repo-guard checks that each exists (selftest/workflows.sh).
  # The deploy file depends on the environment's role in the path (ADR 0008 P7): the build environment deploys
  # with app-deploy.yml; a promoted environment only receives images through app-promote.yml.
  is_promoted = var.promotion_source_account_id != null
  workflow_files = {
    apply  = ["terraform-iac.yml", "terraform-destroy.yml"]
    deploy = [local.is_promoted ? "app-promote.yml" : "app-deploy.yml"]
  }
  job_workflow_refs = {
    for k, files in local.workflow_files : k => [
      for f in files : "${var.github_owner}/${var.github_repo}/.github/workflows/${f}@refs/heads/main"
    ]
  }

  trust = {
    # Plan: a pull_request run has ref refs/pull/<N>/merge; a pull_request_target run has the base ref, so the
    # StringLike (the only one in any trust policy, wildcard = PR number only) refuses it even though sub matches.
    plan   = { sub = "${local.gh_sub_prefix}:pull_request", ref = "refs/pull/*/merge", ref_test = "StringLike", workflows = null }
    apply  = { sub = "${local.gh_sub_prefix}:environment:${var.env}", ref = "refs/heads/main", ref_test = "StringEquals", workflows = local.job_workflow_refs.apply }
    deploy = { sub = "${local.gh_sub_prefix}:environment:${var.env}", ref = "refs/heads/main", ref_test = "StringEquals", workflows = local.job_workflow_refs.deploy }
  }

  # Name contract (ADR 0002, ADR 0012 L3, L4): envs/<env> and modules/app-lambda must use exactly these names,
  # because the apply and deploy roles below are scoped by them.
  resource_names = {
    function         = "${local.name}-app"
    alias            = "live"
    api              = "${local.name}-api"
    app_exec_role    = "${local.name}-app-exec"
    boundary         = "${local.name}-app-boundary"
    ecr_repository   = "${local.name}-app"
    lambda_log_group = "/aws/lambda/${local.name}-app"
    api_log_group    = "/aws/apigateway/${local.name}-api"
    secret           = "${var.prefix}/${var.env}/app-api-key"
  }

  role_names = {
    plan   = "${local.name}-gha-plan"
    apply  = "${local.name}-gha-apply"
    deploy = "${local.name}-gha-deploy"
  }
  guardrails_name = "${local.name}-gha-guardrails"

  # Value of the Project tag (NFR-8): provider default_tags here and in envs/<env> use the same string.
  tag_project = "ship-it-serverless"

  # ARN builders.
  iam_arn      = "arn:${local.partition}:iam::${local.account_id}"
  svc_arn      = { for s in ["lambda", "ecr", "logs", "secretsmanager", "cloudwatch"] : s => "arn:${local.partition}:${s}:${local.region}:${local.account_id}" }
  boundary_arn = "${local.iam_arn}:policy/${local.resource_names.boundary}"

  # The one role the apply role may create, change and pass (ADR 0012 L9): the function's execution role.
  app_exec_role_arn = "${local.iam_arn}:role/${local.resource_names.app_exec_role}"

  ecr_repo_app = "${local.svc_arn["ecr"]}:repository/${local.resource_names.ecr_repository}"
  # Promotion source repository (ADR 0008 P9): read-only, the one repository, in the source account.
  ecr_repo_source = (
    local.is_promoted
    ? "arn:${local.partition}:ecr:${local.region}:${var.promotion_source_account_id}:repository/${var.prefix}-${var.promotion_source_env}-app"
    : null
  )
  secret_pattern = "${local.svc_arn["secretsmanager"]}:secret:${var.prefix}/${var.env}/*"

  # Lambda resource ARNs: the unqualified ARN covers the function, the ":*" form its versions and aliases.
  function_arns_env = [
    "${local.svc_arn["lambda"]}:function:${local.name}-*",
    "${local.svc_arn["lambda"]}:function:${local.name}-*:*",
  ]
  function_arn_app = "${local.svc_arn["lambda"]}:function:${local.resource_names.function}"

  # API Gateway management ARNs have no account ID. HTTP API IDs are random, so /apis/* is every HTTP API of this
  # region in this account; the apply role is the only writer and the account holds only this lab.
  apigateway_arn = "arn:${local.partition}:apigateway:${local.region}::"

  # The two log groups of an env (ADR 0012 L10), as group ARNs and with ":*" for their streams.
  log_group_arns = flatten([
    for p in ["/aws/lambda/${local.name}-*", "/aws/apigateway/${local.name}-*"] : [
      "${local.svc_arn["logs"]}:log-group:${p}",
      "${local.svc_arn["logs"]}:log-group:${p}:*",
    ]
  ])
}
