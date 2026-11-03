# Permission policies: guardrails, plan, apply, deploy, boundary (B14 to B20, ADR 0012 L9).
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
          "arn:aws:iam::123456789012:policy/sis-dev-app-boundary",
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

# ADR 0012 L9, Finding 9: the apply role passes exactly the execution role, to Lambda only; the deploy role can
# never pass a role (no Allow, plus an explicit Deny).
run "pass_role_is_exact" {
  command = plan

  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.apply.statement : s if contains(s.actions, "iam:PassRole")]) == 1
      && alltrue([
        for s in data.aws_iam_policy_document.apply.statement : (
          s.effect == "Allow"
          && toset(s.actions) == toset(["iam:PassRole"])
          && toset(s.resources) == toset(["arn:aws:iam::123456789012:role/sis-dev-app-exec"])
          && length(s.condition) == 1
          && anytrue([
            for c in s.condition : c.test == "StringEquals" && c.variable == "iam:PassedToService" && toset(c.values) == toset(["lambda.amazonaws.com"])
          ])
        ) if contains(s.actions, "iam:PassRole")
      ])
    )
    error_message = "apply PassRole must be one statement on exactly sis-dev-app-exec with iam:PassedToService = lambda.amazonaws.com"
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.deploy.statement : s if s.effect == "Allow" && contains(s.actions, "iam:PassRole")]) == 0
    error_message = "the deploy role must not allow iam:PassRole"
  }

  assert {
    condition = [
      for s in data.aws_iam_policy_document.deploy.statement : [s.effect, toset(s.actions), toset(s.resources)]
      if s.sid == "DenyPassRole"
    ] == [["Deny", toset(["iam:PassRole"]), toset(["*"])]]
    error_message = "the deploy role needs the explicit DenyPassRole statement on every resource"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : !anytrue([for a in s.actions : startswith(a, "iam:")])
      if s.effect == "Allow"
    ])
    error_message = "the deploy role has no IAM Allow at all"
  }
}

run "deploy_lambda_scope" {
  command = plan

  assert {
    condition = [
      for s in data.aws_iam_policy_document.deploy.statement : [s.effect, toset(s.actions), toset(s.resources)]
      if s.sid == "LambdaReleaseOneFunction"
      ] == [[
        "Allow",
        toset([
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion",
          "lambda:ListVersionsByFunction",
          "lambda:GetAlias",
          "lambda:UpdateAlias",
          "lambda:InvokeFunction",
        ]),
        toset([
          "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app",
          "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app:*",
        ]),
    ]]
    error_message = "the deploy Lambda statement must be the L9 release actions on the one function and its qualified ARNs"
  }

  # L8: DeleteFunction only on qualified ARNs, so it prunes versions but can never delete the function.
  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.deploy.statement : s if contains(s.actions, "lambda:DeleteFunction")]) == 1
      && alltrue([
        for s in data.aws_iam_policy_document.deploy.statement : (
          s.effect == "Allow"
          && toset(s.actions) == toset(["lambda:DeleteFunction"])
          && toset(s.resources) == toset(["arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app:*"])
        ) if contains(s.actions, "lambda:DeleteFunction")
      ])
    )
    error_message = "deploy lambda:DeleteFunction must be alone in its statement, on the qualified function ARN only"
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.deploy.statement : [
        for r in s.resources : r == "*" || !startswith(r, "arn:aws:lambda:") || startswith(r, "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-app")
      ]
    ]))
    error_message = "every deploy Lambda resource must be the one function sis-dev-app"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : !anytrue([
        for a in s.actions : contains(["lambda:CreateFunction", "lambda:CreateAlias", "lambda:DeleteAlias", "lambda:AddPermission", "lambda:RemovePermission", "lambda:PutFunctionConcurrency"], a)
      ])
    ])
    error_message = "the deploy must not create functions or aliases, change permissions or concurrency"
  }

  assert {
    condition = [
      for s in data.aws_iam_policy_document.deploy.statement : [toset(s.actions), toset(s.resources)]
      if s.sid == "ApiGatewayRead"
      ] == [[
        toset(["apigateway:GET"]),
        toset(["arn:aws:apigateway:ap-southeast-1::/apis", "arn:aws:apigateway:ap-southeast-1::/apis/*"]),
    ]]
    error_message = "the deploy may only GET HTTP APIs of its region"
  }

  assert {
    condition = [
      for s in data.aws_iam_policy_document.deploy.statement : [toset(s.actions), toset(s.resources)]
      if s.sid == "CanaryMetrics"
    ] == [[toset(["cloudwatch:GetMetricStatistics"]), toset(["*"])]]
    error_message = "the canary judgment reads metrics with GetMetricStatistics only"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : !anytrue([for a in s.actions : startswith(a, "ecs:") || startswith(a, "ec2:") || startswith(a, "elasticloadbalancing:")])
    ])
    error_message = "the deploy has no ECS, EC2 or ELB action left (ADR 0012 L11)"
  }
}

run "apply_lambda_and_front_door_scope" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : toset(s.resources) == toset([
        "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-*",
        "arn:aws:lambda:ap-southeast-1:123456789012:function:sis-dev-*:*",
      ]) if anytrue([for a in s.actions : startswith(a, "lambda:")])
    ])
    error_message = "apply Lambda actions must be scoped to this env's functions and their qualified ARNs"
  }

  assert {
    condition = alltrue([
      for a in [
        "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction", "lambda:UpdateFunctionConfiguration",
        "lambda:PublishVersion", "lambda:CreateAlias", "lambda:UpdateAlias", "lambda:AddPermission",
        "lambda:RemovePermission", "lambda:GetPolicy", "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency",
        "lambda:TagResource", "lambda:ListTags",
      ] : contains(flatten([for s in data.aws_iam_policy_document.apply.statement : tolist(s.actions) if s.sid == "LambdaFunction"]), a)
    ])
    error_message = "the apply role must manage the function, alias, permission, concurrency and tags"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : toset(s.resources) == toset([
        "arn:aws:apigateway:ap-southeast-1::/apis",
        "arn:aws:apigateway:ap-southeast-1::/apis/*",
        "arn:aws:apigateway:ap-southeast-1::/tags/*",
      ]) if anytrue([for a in s.actions : startswith(a, "apigateway:")])
    ])
    error_message = "apply API Gateway actions must be scoped to /apis, /apis/* and /tags/* of the region"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : toset(s.resources) == toset([
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-*",
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-*:*",
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/apigateway/sis-dev-*",
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/apigateway/sis-dev-*:*",
      ]) if contains(s.actions, "logs:CreateLogGroup")
    ])
    error_message = "log group writes must be scoped to the two log group patterns of this env"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : toset(s.resources) == toset(["arn:aws:cloudwatch:ap-southeast-1:123456789012:alarm:sis-dev-*"])
      if anytrue([for a in s.actions : startswith(a, "cloudwatch:")])
    ])
    error_message = "alarm actions must be scoped to this env's alarms"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : (
        toset(s.resources) == toset(["arn:aws:iam::123456789012:role/aws-service-role/ops.apigateway.amazonaws.com/*"])
        && anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "iam:AWSServiceName" && toset(c.values) == toset(["ops.apigateway.amazonaws.com"])])
      ) if contains(s.actions, "iam:CreateServiceLinkedRole")
    ])
    error_message = "the only service-linked role is API Gateway's"
  }
}

# ADR 0012 L4: the repository and its policy are bootstrap's. The apply role reads the one repository only.
run "apply_ecr_read_only" {
  command = plan

  assert {
    condition = [
      for s in data.aws_iam_policy_document.apply.statement : [toset(s.actions), toset(s.resources)]
      if anytrue([for a in s.actions : startswith(a, "ecr:")])
      ] == [[
        toset(["ecr:DescribeImages", "ecr:DescribeRepositories"]),
        toset(["arn:aws:ecr:ap-southeast-1:123456789012:repository/sis-dev-app"]),
    ]]
    error_message = "the apply role may only describe the one repository (no create, delete, push or policy write)"
  }

  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.plan, data.aws_iam_policy_document.apply, data.aws_iam_policy_document.deploy] :
      alltrue([for s in doc.statement : !contains(s.actions, "ecr:SetRepositoryPolicy") if s.effect == "Allow"])
    ])
    error_message = "no CI role may set a repository policy, so Lambda can never widen it (L4)"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : !anytrue([for a in s.actions : startswith(a, "ecs:") || startswith(a, "ec2:") || startswith(a, "elasticloadbalancing:")])
    ])
    error_message = "the apply role has no ECS, EC2 or ELB action left (ADR 0012 L11)"
  }
}

run "apply_iam_requires_boundary" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : anytrue([
        for c in s.condition : c.test == "StringEquals" && c.variable == "iam:PermissionsBoundary" && toset(c.values) == toset(["arn:aws:iam::123456789012:policy/sis-dev-app-boundary"])
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
          && toset(s.resources) == toset(["arn:aws:iam::123456789012:role/sis-dev-app-exec"])
          && anytrue([for c in s.condition : c.variable == "iam:PermissionsBoundary"])
        ) if s.effect == "Allow"
      ])
    ])
    error_message = "every mutating IAM role action must sit under the boundary condition on exactly the execution role ARN"
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
      for s in data.aws_iam_policy_document.apply.statement : toset(s.resources) == toset(["arn:aws:iam::123456789012:role/sis-dev-app-exec"])
      if contains(["IamAppRoleBounded", "IamAppRoleRead", "PassAppExecRole"], s.sid)
    ])
    error_message = "app role statements must target exactly sis-dev-app-exec"
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

run "no_broad_allows" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.app_boundary,
      ] : [for s in doc.statement : !contains(s.actions, "*") if s.effect == "Allow"]
    ]))
    error_message = "no Allow statement may use Action *"
  }

  # The B20 list as rewritten by ADR 0012 L9: each API below has no resource-level support.
  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.app_boundary,
        ] : [
        for s in doc.statement : alltrue([
          for a in s.actions : contains([
            "ecr:GetAuthorizationToken",
            "cloudwatch:GetMetricStatistics",
            "logs:DescribeLogGroups",
            "logs:CreateLogDelivery",
            "logs:GetLogDelivery",
            "logs:UpdateLogDelivery",
            "logs:DeleteLogDelivery",
            "logs:ListLogDeliveries",
            "logs:PutResourcePolicy",
            "logs:DescribeResourcePolicies",
          ], a)
        ]) if s.effect == "Allow" && contains(s.resources, "*")
      ]
    ]))
    error_message = "Allow with Resource * is limited to the B20 list (ADR 0012 L9)"
  }

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.app_boundary,
      ] : [for s in doc.statement : alltrue([for a in s.actions : !strcontains(a, "*")]) if s.effect == "Allow"]
    ]))
    error_message = "no action wildcard in any Allow"
  }
}

run "boundary_contents" {
  command = plan

  assert {
    condition     = aws_iam_policy.app_boundary.name == "sis-dev-app-boundary"
    error_message = "boundary policy name"
  }

  assert {
    condition = {
      for s in data.aws_iam_policy_document.app_boundary.statement : s.sid => [s.effect, toset(s.actions), toset(s.resources)]
      } == {
      LambdaLogsWrite = ["Allow", toset(["logs:CreateLogStream", "logs:PutLogEvents"]), toset([
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-*",
        "arn:aws:logs:ap-southeast-1:123456789012:log-group:/aws/lambda/sis-dev-*:*",
      ])]
      AppSecretRead = ["Allow", toset(["secretsmanager:GetSecretValue"]), toset(["arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/*"])]
    }
    error_message = "the boundary allows only log writes to /aws/lambda/sis-dev-* and reading sis/dev secrets"
  }
}

run "name_contract_output" {
  command = plan

  assert {
    condition = local.resource_names == {
      function         = "sis-dev-app"
      alias            = "live"
      api              = "sis-dev-api"
      app_exec_role    = "sis-dev-app-exec"
      boundary         = "sis-dev-app-boundary"
      ecr_repository   = "sis-dev-app"
      lambda_log_group = "/aws/lambda/sis-dev-app"
      api_log_group    = "/aws/apigateway/sis-dev-api"
      secret           = "sis/dev/app-api-key"
    }
    error_message = "name contract (ADR 0012 L3, L4)"
  }
}
