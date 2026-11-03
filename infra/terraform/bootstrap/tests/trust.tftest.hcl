# OIDC trust: exact subjects, immutable IDs, ref pin on every role (B12, B13). The only StringLike is the
# plan role's pull request merge ref, which keeps pull_request_target runs (base ref) out.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

variables {
  # The fixture names use the prefix sis, whatever project.env holds (a fork).
  prefix          = "sis"
  aws_account_id  = "123456789012"
  github_owner_id = "111"
  github_repo_id  = "222"
  budget_email    = "ops@example.com"
}

run "subjects_use_immutable_ids" {
  command = plan

  assert {
    condition     = local.gh_sub_prefix == "repo:trungleviet-agilityio@111/ship-it-safely@222"
    error_message = "gh_sub_prefix must carry the owner and repo IDs"
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:sub"
    ]) == ["repo:trungleviet-agilityio@111/ship-it-safely@222:pull_request"]
    error_message = "plan role sub must be the pull_request subject"
  }

  assert {
    condition = alltrue([
      for k in ["apply", "deploy"] : flatten([
        for c in data.aws_iam_policy_document.trust[k].statement[0].condition : c.values
        if c.variable == "token.actions.githubusercontent.com:sub"
      ]) == ["repo:trungleviet-agilityio@111/ship-it-safely@222:environment:dev"]
    ])
    error_message = "apply and deploy subs must end with :environment:dev"
  }
}

run "conditions_are_exact" {
  command = plan

  assert {
    condition = length(flatten([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : c if c.test == "StringLike"
      ]
    ])) == 1
    error_message = "exactly one StringLike is allowed across all trust policies"
  }

  assert {
    condition = [
      for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c.variable
      if c.test == "StringLike"
    ] == ["token.actions.githubusercontent.com:ref"]
    error_message = "the only StringLike must be on the plan role ref"
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c.values
      if c.test == "StringLike"
    ]) == ["refs/pull/*/merge"]
    error_message = "the only StringLike value must be exactly refs/pull/*/merge"
  }

  assert {
    condition = alltrue(flatten([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : c.test == "StringEquals"
        if !(k == "plan" && c.variable == "token.actions.githubusercontent.com:ref")
      ]
    ]))
    error_message = "every condition except the plan ref must use StringEquals"
  }

  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust : flatten([
        for c in d.statement[0].condition : c.values
        if c.variable == "token.actions.githubusercontent.com:aud"
      ]) == ["sts.amazonaws.com"]
    ])
    error_message = "aud must be sts.amazonaws.com"
  }

  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust : (
        flatten([for c in d.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:repository_id"]) == ["222"]
        && flatten([for c in d.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:repository_owner_id"]) == ["111"]
      )
    ])
    error_message = "repository_id and repository_owner_id must be pinned on every role"
  }

  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust :
      alltrue([for a in d.statement[0].actions : a == "sts:AssumeRoleWithWebIdentity"])
    ])
    error_message = "only sts:AssumeRoleWithWebIdentity may be allowed"
  }
}

run "ref_pinned_on_every_role" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["apply", "deploy"] : flatten([
        for c in data.aws_iam_policy_document.trust[k].statement[0].condition : c.values
        if c.variable == "token.actions.githubusercontent.com:ref"
      ]) == ["refs/heads/main"]
    ])
    error_message = "apply and deploy must pin ref to refs/heads/main"
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:ref"
    ]) == ["refs/pull/*/merge"]
    error_message = "plan must require a pull request merge ref"
  }
}

run "no_wildcards_and_session_duration" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : [
          for v in c.values : !strcontains(v, "*")
        ] if contains(["aud", "sub", "repository_id", "repository_owner_id"], trimprefix(c.variable, "token.actions.githubusercontent.com:"))
      ]
    ]))
    error_message = "no aud, sub or repository value may contain a wildcard"
  }

  assert {
    condition = (
      aws_iam_role.plan.max_session_duration == 3600
      && aws_iam_role.apply.max_session_duration == 3600
      && aws_iam_role.deploy.max_session_duration == 3600
      && aws_iam_role.plan.name == "sis-dev-gha-plan"
      && aws_iam_role.apply.name == "sis-dev-gha-apply"
      && aws_iam_role.deploy.name == "sis-dev-gha-deploy"
    )
    error_message = "roles need max_session_duration 3600 and the contract names"
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" && aws_iam_openid_connect_provider.github.client_id_list == toset(["sts.amazonaws.com"])
    error_message = "OIDC provider url and client id"
  }
}

run "name_based_subject_fallback" {
  command = plan

  variables {
    github_immutable_subject = false
  }

  assert {
    condition     = local.gh_sub_prefix == "repo:trungleviet-agilityio/ship-it-safely"
    error_message = "fallback prefix must use names"
  }
}

run "job_workflow_ref_pinned" {
  command = plan

  assert {
    condition = toset(flatten([
      for c in data.aws_iam_policy_document.trust["apply"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:job_workflow_ref" && c.test == "StringEquals"
      ])) == toset([
      "trungleviet-agilityio/ship-it-safely/.github/workflows/terraform-iac.yml@refs/heads/main",
      "trungleviet-agilityio/ship-it-safely/.github/workflows/terraform-destroy.yml@refs/heads/main",
    ])
    error_message = "apply job_workflow_ref must be exactly the terraform-iac and terraform-destroy files at main"
  }

  assert {
    condition = toset(flatten([
      for c in data.aws_iam_policy_document.trust["deploy"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:job_workflow_ref" && c.test == "StringEquals"
    ])) == toset(["trungleviet-agilityio/ship-it-safely/.github/workflows/app-deploy.yml@refs/heads/main"])
    error_message = "deploy job_workflow_ref must be exactly the app-deploy file at main"
  }

  assert {
    condition = length([
      for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c
      if c.variable == "token.actions.githubusercontent.com:job_workflow_ref"
    ]) == 0
    error_message = "plan must not pin job_workflow_ref (a PR controls its own workflow file)"
  }

  assert {
    condition = length(flatten([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : c
        if c.variable == "token.actions.githubusercontent.com:workflow"
      ]
    ])) == 0
    error_message = "no role may keep the name based workflow condition"
  }

  assert {
    condition = alltrue(flatten([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : [for v in c.values : !strcontains(v, "*")]
        if c.variable == "token.actions.githubusercontent.com:job_workflow_ref"
      ]
    ]))
    error_message = "job_workflow_ref values must not contain a wildcard"
  }

  assert {
    condition = local.workflow_files == {
      apply  = ["terraform-iac.yml", "terraform-destroy.yml"]
      deploy = ["app-deploy.yml"]
    }
    error_message = "workflow file contract"
  }
}

run "only_documented_condition_keys" {
  command = plan

  # Documented GitHub keys in the IAM condition keys reference, plus the global aws:RequestedRegion.
  # event_name and workflow_ref are not on the list.
  assert {
    condition = alltrue(flatten([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : contains(
          ["aud", "sub", "repository_id", "repository_owner_id", "ref", "job_workflow_ref", "aws:RequestedRegion"],
          trimprefix(c.variable, "token.actions.githubusercontent.com:")
        )
      ]
    ]))
    error_message = "trust conditions may only use aud, sub, repository_id, repository_owner_id, ref, job_workflow_ref, aws:RequestedRegion"
  }
}

run "requested_region_pinned_on_every_role" {
  command = plan

  # The alert rule sees one region only; a call through the global endpoint carries us-east-1 and is refused.
  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : c.test == "StringEquals" && c.values == ["ap-southeast-1"]
        if c.variable == "aws:RequestedRegion"
      ] != [] && length([for c in d.statement[0].condition : c if c.variable == "aws:RequestedRegion"]) == 1
    ])
    error_message = "every role must require aws:RequestedRegion = the bootstrap region, exactly once"
  }
}

# ADR 0008 P7: a promoted environment (prod) trusts app-promote.yml for deploy; apply is unchanged.
run "promoted_env_trusts_app_promote" {
  command = plan

  variables {
    env                         = "prod"
    promotion_source_account_id = "222222222222"
  }

  assert {
    condition = toset(flatten([
      for c in data.aws_iam_policy_document.trust["deploy"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:job_workflow_ref" && c.test == "StringEquals"
    ])) == toset(["trungleviet-agilityio/ship-it-safely/.github/workflows/app-promote.yml@refs/heads/main"])
    error_message = "a promoted env's deploy job_workflow_ref must be exactly the app-promote file at main"
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.trust["deploy"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:sub"
    ]) == ["repo:trungleviet-agilityio@111/ship-it-safely@222:environment:prod"]
    error_message = "a promoted env's deploy sub must end with :environment:prod"
  }

  assert {
    condition     = local.workflow_files.apply == ["terraform-iac.yml", "terraform-destroy.yml"]
    error_message = "apply files do not depend on promotion"
  }
}
