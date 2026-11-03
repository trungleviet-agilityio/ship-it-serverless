# Permission policies: guardrails, plan, apply, deploy, boundary (B14 to B20).
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
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-southeast-1:123456789012:sis-dev-security-alerts" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:ap-southeast-1:123456789012:rule/sis-dev-oidc-unexpected" }
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

run "guardrails_deny_and_attach" {
  command = plan

  assert {
    condition = alltrue([
      for a in [
        "secretsmanager:GetSecretValue",
        "secretsmanager:BatchGetSecretValue",
        "secretsmanager:PutSecretValue",
        "ssm:GetParameter*",
        "sts:AssumeRole",
        ] : contains(flatten([
          for s in data.aws_iam_policy_document.guardrails.statement : tolist(s.actions) if s.effect == "Deny"
      ]), a)
    ])
    error_message = "guardrails must deny secret reads, SSM reads and role chaining"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.guardrails.statement : toset(s.resources) == toset(["*"])
      if contains(["G1DenySecretValues", "G2DenySsmParameterReads", "G3DenyRoleChaining"], s.sid)
    ])
    error_message = "G1, G2 and G3 must apply to every resource"
  }

  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.guardrails.statement : s if s.sid == "G4DenyBootstrapIamWrites"]) == 1
      && length([for s in data.aws_iam_policy_document.guardrails.statement : s if s.sid == "G5DenyBootstrapState"]) == 1
    )
    error_message = "G4 and G5 statements must exist exactly once"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.guardrails.statement : (
        s.effect == "Deny"
        && toset(s.resources) == toset([
          "arn:aws:iam::123456789012:role/sis-dev-gha-*",
          "arn:aws:iam::123456789012:policy/sis-dev-gha-*",
          "arn:aws:iam::123456789012:policy/sis-dev-ecs-boundary",
          "arn:aws:iam::123456789012:oidc-provider/*",
        ])
        && alltrue([
          for a in ["iam:Create*", "iam:Put*", "iam:Update*", "iam:Delete*", "iam:Attach*", "iam:Detach*", "iam:Add*", "iam:Remove*", "iam:Tag*", "iam:Untag*", "iam:*PermissionsBoundary", "iam:*PolicyVersion"] :
          contains(s.actions, a)
        ])
      ) if s.sid == "G4DenyBootstrapIamWrites"
    ])
    error_message = "G4 must deny IAM writes (including Add* and Remove*) on the gha roles, gha policies, boundary and OIDC providers"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.guardrails.statement : (
        s.effect == "Deny"
        && toset(s.resources) == toset(["arn:aws:s3:::sis-dev-tfstate-123456789012-ap-southeast-1-an/bootstrap/*"])
        && toset(s.actions) == toset(["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*"])
      ) if s.sid == "G5DenyBootstrapState"
    ])
    error_message = "G5 must deny object access under bootstrap/*"
  }

  assert {
    condition = (
      toset(keys(aws_iam_role_policy_attachment.guardrails)) == toset(["plan", "apply", "deploy"])
      && alltrue([for k, a in aws_iam_role_policy_attachment.guardrails : a.policy_arn == aws_iam_policy.guardrails.arn])
    )
    error_message = "guardrails must be attached to all three roles"
  }
}

run "guardrails_protect_audit_resources" {
  command = plan

  # ADR 0007 S28: one Deny per target. A shared resource list would apply every action to every resource.
  assert {
    condition = {
      for s in data.aws_iam_policy_document.guardrails.statement : s.sid => {
        effect    = s.effect
        actions   = toset(s.actions)
        resources = toset(s.resources)
      } if startswith(s.sid, "G6")
      } == {
      G6DenyAuditTrail = { effect = "Deny", actions = toset(["cloudtrail:*"]), resources = toset(["*"]) }
      G6DenyAlertRule  = { effect = "Deny", actions = toset(["events:*"]), resources = toset(["arn:aws:events:ap-southeast-1:123456789012:rule/sis-dev-oidc-unexpected"]) }
      G6DenyAlertTopic = { effect = "Deny", actions = toset(["sns:*"]), resources = toset(["arn:aws:sns:ap-southeast-1:123456789012:sis-dev-security-alerts"]) }
      G6DenyTrailBucket = {
        effect  = "Deny"
        actions = toset(["s3:*"])
        resources = toset([
          "arn:aws:s3:::sis-dev-cloudtrail-123456789012-ap-southeast-1-an",
          "arn:aws:s3:::sis-dev-cloudtrail-123456789012-ap-southeast-1-an/*",
        ])
      }
    }
    error_message = "G6 must deny cloudtrail, the alert rule, the alert topic and the trail bucket, each on its own resources"
  }
}

run "plan_role" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "plan role needs ReadOnlyAccess"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.plan.statement : (
        s.effect == "Deny"
        && contains(s.actions, "s3:GetObject")
        && toset(s.not_resources) == toset([
          "arn:aws:s3:::sis-dev-tfstate-123456789012-ap-southeast-1-an/envs/dev/terraform.tfstate",
          "arn:aws:s3:::sis-dev-tfstate-123456789012-ap-southeast-1-an/envs/dev/terraform.tfstate.tflock",
        ])
      )
    ])
    error_message = "plan role needs the NotResource s3 read deny on exactly the envs/dev state and lock objects"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.plan.statement : (
        toset(s.resources) == toset(["arn:aws:s3:::sis-dev-tfstate-123456789012-ap-southeast-1-an"])
        && anytrue([
          for c in s.condition : c.test == "StringLike" && c.variable == "s3:prefix" && toset(c.values) == toset(["envs/dev/terraform.tfstate", "env:/*"])
        ])
      ) if contains(s.actions, "s3:ListBucket")
    ])
    error_message = "plan ListBucket must allow the state key and the workspace listing prefix env:/ (S3 backend)"
  }
}

run "pass_role_is_exact" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [data.aws_iam_policy_document.apply, data.aws_iam_policy_document.deploy] : [
        for s in doc.statement : (
          toset(s.resources) == toset([
            "arn:aws:iam::123456789012:role/sis-dev-ecs-exec",
            "arn:aws:iam::123456789012:role/sis-dev-ecs-task",
          ])
          && anytrue([
            for c in s.condition : c.test == "StringEquals" && c.variable == "iam:PassedToService" && toset(c.values) == toset(["ecs-tasks.amazonaws.com"])
          ])
        ) if contains(s.actions, "iam:PassRole")
      ]
    ]))
    error_message = "every iam:PassRole must name the two ECS roles and set PassedToService"
  }

  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.apply, data.aws_iam_policy_document.deploy] :
      length([for s in doc.statement : s if contains(s.actions, "iam:PassRole")]) == 1
    ])
    error_message = "apply and deploy each have exactly one PassRole statement"
  }
}

run "deploy_scope" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : toset(s.resources) == toset(["arn:aws:ecr:ap-southeast-1:123456789012:repository/sis-dev-app"])
      if s.sid == "EcrPushOneRepo"
    ])
    error_message = "deploy ECR push resources must be exactly the one repository"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : !anytrue([for a in s.actions : startswith(a, "s3:")])
    ])
    error_message = "deploy has no state access"
  }
}

# ADR 0006, G14: the deploy preflight may read the metadata of the one app secret, never its value.
run "deploy_secret_metadata_only" {
  command = plan

  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.deploy.statement : s if s.sid == "DescribeAppSecretMetadata"]) == 1
      && alltrue([
        for s in data.aws_iam_policy_document.deploy.statement :
        s.effect == "Allow" && toset(s.actions) == toset(["secretsmanager:DescribeSecret"]) && toset(s.resources) == toset(["arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-??????"])
        if s.sid == "DescribeAppSecretMetadata"
      ])
    )
    error_message = "DescribeAppSecretMetadata must allow exactly secretsmanager:DescribeSecret on the one app secret name (-?????? suffix)"
  }

  assert {
    condition = (
      length(flatten([
        for s in data.aws_iam_policy_document.deploy.statement : [for a in s.actions : a if startswith(a, "secretsmanager:")]
      ])) == 1
    )
    error_message = "the only Secrets Manager action in the deploy policy is DescribeSecret"
  }

  assert {
    condition     = contains(flatten([for s in data.aws_iam_policy_document.guardrails.statement : tolist(s.actions) if s.effect == "Deny"]), "secretsmanager:GetSecretValue")
    error_message = "the guardrail must still deny GetSecretValue, which wins over the DescribeSecret allow"
  }
}

run "apply_iam_requires_boundary" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : anytrue([
        for c in s.condition : c.test == "StringEquals" && c.variable == "iam:PermissionsBoundary" && toset(c.values) == toset(["arn:aws:iam::123456789012:policy/sis-dev-ecs-boundary"])
      ]) if contains(s.actions, "iam:CreateRole")
    ])
    error_message = "iam:CreateRole needs the boundary condition"
  }

  # Per the IAM Service Authorization Reference all six actions support iam:PermissionsBoundary.
  assert {
    condition = alltrue([
      for a in ["iam:CreateRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary", "iam:UpdateAssumeRolePolicy", "iam:DeleteRole"] :
      anytrue([
        for s in data.aws_iam_policy_document.apply.statement : (
          contains(s.actions, a)
          && toset(s.resources) == toset(["arn:aws:iam::123456789012:role/sis-dev-ecs-exec", "arn:aws:iam::123456789012:role/sis-dev-ecs-task"])
          && anytrue([for c in s.condition : c.variable == "iam:PermissionsBoundary"])
        ) if s.effect == "Allow"
      ])
    ])
    error_message = "every mutating IAM role action must sit under the boundary condition on exactly the two ecs role ARNs"
  }

  # No IAM write or read on roles may target a wildcard role pattern (M1).
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : alltrue([for r in s.resources : !strcontains(r, "role/") || !strcontains(r, "*") || strcontains(r, "role/aws-service-role/")])
      if s.effect == "Allow" && anytrue([for a in s.actions : startswith(a, "iam:") && a != "iam:CreateServiceLinkedRole"])
    ])
    error_message = "no IAM action may target a wildcard role pattern (service-linked roles excepted)"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : toset(s.resources) == toset(["arn:aws:iam::123456789012:role/sis-dev-ecs-exec", "arn:aws:iam::123456789012:role/sis-dev-ecs-task"])
      if contains(["IamEcsRolesBounded", "IamEcsRolesRead", "PassEcsRoles"], s.sid)
    ])
    error_message = "ecs role statements must target exactly sis-dev-ecs-exec and sis-dev-ecs-task"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.apply.statement : s.effect == "Deny" && contains(s.actions, "iam:DeleteRolePermissionsBoundary")
    ])
    error_message = "apply must deny removing the boundary"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : !anytrue([for a in s.actions : startswith(a, "iam:Attach")])
    ])
    error_message = "apply must not attach managed policies"
  }
}

run "apply_state_listing" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : (
        toset(s.resources) == toset(["arn:aws:s3:::sis-dev-tfstate-123456789012-ap-southeast-1-an"])
        && anytrue([
          for c in s.condition : c.test == "StringLike" && c.variable == "s3:prefix" && toset(c.values) == toset(["envs/dev/terraform.tfstate", "env:/*"])
        ])
      ) if contains(s.actions, "s3:ListBucket")
    ])
    error_message = "apply ListBucket must allow the state key and the workspace listing prefix env:/ (S3 backend)"
  }
}

run "ecs_task_size_and_update_conditions" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [data.aws_iam_policy_document.apply, data.aws_iam_policy_document.deploy] : [
        for s in doc.statement : (
          anytrue([for c in s.condition : c.test == "NumericLessThanEquals" && c.variable == "ecs:task-cpu" && toset(c.values) == toset(["512"])])
          && anytrue([for c in s.condition : c.test == "NumericLessThanEquals" && c.variable == "ecs:task-memory" && toset(c.values) == toset(["1024"])])
        ) if contains(s.actions, "ecs:RegisterTaskDefinition")
      ]
    ]))
    error_message = "RegisterTaskDefinition needs ecs:task-cpu <= 512 and ecs:task-memory <= 1024 in apply and deploy"
  }

  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.apply, data.aws_iam_policy_document.deploy] :
      length([for s in doc.statement : s if contains(s.actions, "ecs:RegisterTaskDefinition")]) == 1
    ])
    error_message = "apply and deploy each have exactly one RegisterTaskDefinition statement"
  }

  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.deploy.statement : s if contains(s.actions, "ecs:UpdateService")]) == 1
      && alltrue([
        for s in data.aws_iam_policy_document.deploy.statement : anytrue([
          for c in s.condition : (
            c.test == "ArnLike"
            && c.variable == "ecs:task-definition"
            && toset(c.values) == toset(["arn:aws:ecs:ap-southeast-1:123456789012:task-definition/sis-dev-app:*"])
          )
        ]) if contains(s.actions, "ecs:UpdateService")
      ])
    )
    error_message = "deploy UpdateService must be limited to the sis-dev-app task definition family"
  }
}

run "apply_ec2_tag_scoping" {
  command = plan

  # No create statement guarded by RequestTag may span the whole region.
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : alltrue([for r in s.resources : !endswith(r, ":*")])
      if s.effect == "Allow" && anytrue([for c in s.condition : startswith(c.variable, "aws:RequestTag/")])
    ])
    error_message = "RequestTag statements must name resource types, not the region-wide ec2 ARN"
  }

  # Authorize* never rides on a RequestTag condition and is gated by tags on the parent security group.
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : (
        !anytrue([for c in s.condition : startswith(c.variable, "aws:RequestTag/")])
        && alltrue([
          for r in s.resources : contains([
            "arn:aws:ec2:ap-southeast-1:123456789012:security-group/*",
            "arn:aws:ec2:ap-southeast-1:123456789012:security-group-rule/*",
          ], r)
        ])
        && (
          !contains(s.resources, "arn:aws:ec2:ap-southeast-1:123456789012:security-group/*")
          || (
            anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:ResourceTag/Project" && toset(c.values) == toset(["ship-it-safely"])])
            && anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:ResourceTag/Env" && toset(c.values) == toset(["dev"])])
          )
        )
      ) if s.effect == "Allow" && anytrue([for a in s.actions : startswith(a, "ec2:AuthorizeSecurityGroup")])
    ])
    error_message = "Authorize* may only target security-group/* (with ResourceTag Project and Env) and security-group-rule/*"
  }

  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.apply.statement : s if contains(s.actions, "ec2:AuthorizeSecurityGroupIngress")]) == 2
      && alltrue([
        for s in data.aws_iam_policy_document.apply.statement : (
          contains(s.actions, "ec2:AuthorizeSecurityGroupIngress") == contains(s.actions, "ec2:AuthorizeSecurityGroupEgress")
        )
      ])
    )
    error_message = "Authorize ingress and egress are granted together on the security group and on the rule"
  }

  # Child creates: RequestTag on the new resource type only, ResourceTag on the parent vpc.
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : (
        s.effect == "Allow"
        && (
          (
            toset(s.resources) == toset(["arn:aws:ec2:ap-southeast-1:123456789012:vpc/*"])
            && !anytrue([for c in s.condition : startswith(c.variable, "aws:RequestTag/")])
            && anytrue([for c in s.condition : c.variable == "aws:ResourceTag/Project" && toset(c.values) == toset(["ship-it-safely"])])
            && anytrue([for c in s.condition : c.variable == "aws:ResourceTag/Env" && toset(c.values) == toset(["dev"])])
          )
          || (
            alltrue([for r in s.resources : contains([
              "arn:aws:ec2:ap-southeast-1:123456789012:subnet/*",
              "arn:aws:ec2:ap-southeast-1:123456789012:route-table/*",
              "arn:aws:ec2:ap-southeast-1:123456789012:security-group/*",
            ], r)])
            && anytrue([for c in s.condition : c.variable == "aws:RequestTag/Project" && toset(c.values) == toset(["ship-it-safely"])])
            && anytrue([for c in s.condition : c.variable == "aws:RequestTag/Env" && toset(c.values) == toset(["dev"])])
          )
        )
      ) if anytrue([for a in s.actions : contains(["ec2:CreateSubnet", "ec2:CreateRouteTable", "ec2:CreateSecurityGroup"], a)])
    ])
    error_message = "CreateSubnet, CreateRouteTable and CreateSecurityGroup need RequestTag on the new resource and ResourceTag on the parent vpc"
  }

  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.apply.statement : s if contains(s.actions, "ec2:CreateVpc")]) == 1
      && alltrue([
        for s in data.aws_iam_policy_document.apply.statement : (
          toset(s.resources) == toset([
            "arn:aws:ec2:ap-southeast-1:123456789012:vpc/*",
            "arn:aws:ec2:ap-southeast-1:123456789012:internet-gateway/*",
          ])
          && anytrue([for c in s.condition : c.variable == "aws:RequestTag/Project"])
          && anytrue([for c in s.condition : c.variable == "aws:RequestTag/Env"])
        ) if contains(s.actions, "ec2:CreateVpc")
      ])
    )
    error_message = "CreateVpc and CreateInternetGateway use RequestTag on vpc/* and internet-gateway/*"
  }

  # Tag-on-create stays in sync with the create actions.
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : (
        toset(flatten([for c in s.condition : c.values if c.variable == "ec2:CreateAction"])) == toset([
          "CreateVpc", "CreateSubnet", "CreateInternetGateway", "CreateRouteTable", "CreateSecurityGroup",
          "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress",
        ])
      ) if contains(s.actions, "ec2:CreateTags") && anytrue([for c in s.condition : c.variable == "ec2:CreateAction"])
    ])
    error_message = "ec2:CreateAction list must match the create actions"
  }
}

run "no_broad_allows" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.ecs_boundary,
      ] : [for s in doc.statement : !contains(s.actions, "*") if s.effect == "Allow"]
    ]))
    error_message = "no Allow statement may use Action *"
  }

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.ecs_boundary,
        ] : [
        for s in doc.statement : alltrue([
          for a in s.actions : contains([
            "ec2:Describe*",
            "elasticloadbalancing:Describe*",
            "logs:DescribeLogGroups",
            "ecs:DescribeTaskDefinition",
            "ecs:DeregisterTaskDefinition",
            "ecr:GetAuthorizationToken",
          ], a)
        ]) if s.effect == "Allow" && contains(s.resources, "*")
      ]
    ]))
    error_message = "Allow with Resource * is limited to the B20 list"
  }

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.ecs_boundary,
      ] : [for s in doc.statement : alltrue([for a in s.actions : !endswith(a, "*") || endswith(a, ":Describe*")]) if s.effect == "Allow"]
    ]))
    error_message = "action wildcards in Allow are limited to Describe*"
  }
}

run "boundary_contents" {
  command = plan

  assert {
    condition     = aws_iam_policy.ecs_boundary.name == "sis-dev-ecs-boundary"
    error_message = "boundary policy name"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ecs_boundary.statement :
      contains(s.actions, "secretsmanager:GetSecretValue") && toset(s.resources) == toset(["arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/*"])
    ])
    error_message = "boundary may read only sis/dev secrets"
  }
}

run "name_contract_output" {
  command = plan

  assert {
    condition = (
      local.resource_names.ecs_cluster == "sis-dev-cluster"
      && local.resource_names.ecs_service == "sis-dev-app"
      && local.resource_names.ecr_repository == "sis-dev-app"
      && local.resource_names.ecs_exec_role == "sis-dev-ecs-exec"
      && local.resource_names.ecs_task_role == "sis-dev-ecs-task"
      && local.resource_names.task_family == "sis-dev-app"
      && local.resource_names.log_group == "/ecs/sis-dev-app"
      && local.resource_names.alb == "sis-dev-alb"
      && local.resource_names.target_group == "sis-dev-tg"
      && local.resource_names.secret == "sis/dev/app-api-key"
      && local.resource_names.boundary == "sis-dev-ecs-boundary"
      && length(local.resource_names) == 11
    )
    error_message = "name contract"
  }
}

run "apply_e3_additions" {
  command = plan

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.apply.statement : s
      if s.sid == "Ec2ValidateSgQuotasOnTaggedGroup"
      && s.effect == "Allow"
      && s.actions == toset(["ec2:ValidateSecurityGroupQuotasForInterface"])
      && s.resources == toset(["arn:aws:ec2:ap-southeast-1:123456789012:security-group/*"])
      && anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:ResourceTag/Project" && toset(c.values) == toset(["ship-it-safely"])])
      && anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:ResourceTag/Env" && toset(c.values) == toset(["dev"])])
    ]) == 1
    error_message = "Ec2ValidateSgQuotasOnTaggedGroup: one action on security-group/* with ResourceTag Project and Env"
  }

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.apply.statement : s
      if s.sid == "IamEcsRolesRead"
      && contains(s.actions, "iam:ListRoleTags")
      && s.resources == toset(["arn:aws:iam::123456789012:role/sis-dev-ecs-exec", "arn:aws:iam::123456789012:role/sis-dev-ecs-task"])
    ]) == 1
    error_message = "iam:ListRoleTags must be in IamEcsRolesRead on the two exact ecs role ARNs"
  }
}

run "apply_sgs_for_vpc" {
  command = plan

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.apply.statement : s
      if s.sid == "Ec2SgsForTaggedVpc"
      && s.effect == "Allow"
      && s.actions == toset(["ec2:GetSecurityGroupsForVpc"])
      && s.resources == toset(["arn:aws:ec2:ap-southeast-1:123456789012:vpc/*"])
      && anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:ResourceTag/Project" && toset(c.values) == toset(["ship-it-safely"])])
      && anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:ResourceTag/Env" && toset(c.values) == toset(["dev"])])
    ]) == 1
    error_message = "Ec2SgsForTaggedVpc: GetSecurityGroupsForVpc on vpc/* with ResourceTag Project and Env"
  }
}

# ADR 0008 P9: the build env (dev) has no source pull; a promoted env pulls only from the one source repository.
run "deploy_source_pull_absent_in_build_env" {
  command = plan

  assert {
    condition     = length([for s in data.aws_iam_policy_document.deploy.statement : s if s.sid == "EcrPullFromSource"]) == 0
    error_message = "the build env must not get a source pull statement"
  }
}

run "deploy_source_pull_in_promoted_env" {
  command = plan

  variables {
    env                         = "prod"
    promotion_source_account_id = "222222222222"
  }

  assert {
    condition = [
      for s in data.aws_iam_policy_document.deploy.statement : [toset(s.actions), toset(s.resources)]
      if s.sid == "EcrPullFromSource"
      ] == [[
        toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]),
        toset(["arn:aws:ecr:ap-southeast-1:222222222222:repository/sis-dev-app"]),
    ]]
    error_message = "the source pull must be the two pull actions on the one source repository"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : toset(s.resources) == toset(["arn:aws:ecr:ap-southeast-1:123456789012:repository/sis-prod-app"])
      if s.sid == "EcrPushOneRepo"
    ])
    error_message = "a promoted env pushes only to its own repository"
  }
}

# ADR 0008 P9: the apply role manages the repository policy of its own repositories only.
run "apply_repository_policy_scope" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : toset(s.resources) == toset(["arn:aws:ecr:ap-southeast-1:123456789012:repository/sis-dev-*"])
      if contains(s.actions, "ecr:SetRepositoryPolicy") || contains(s.actions, "ecr:DeleteRepositoryPolicy")
    ])
    error_message = "repository policy writes must be scoped to this env's repositories"
  }
}
