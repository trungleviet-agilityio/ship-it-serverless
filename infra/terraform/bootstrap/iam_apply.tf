resource "aws_iam_role" "apply" {
  name                 = local.role_names.apply
  description          = "GitHub Actions apply for envs/dev, scoped to the services of modules/app-ecs"
  path                 = "/"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
}

locals {
  ec2_arn = "${local.svc_arn["ec2"]}:*"

  # Resource-type ARNs, so no statement guarded by RequestTag spans the whole region.
  ec2_type_arn = { for t in ["vpc", "subnet", "internet-gateway", "route-table", "security-group", "security-group-rule"] : t => "${local.svc_arn["ec2"]}:${t}/*" }

  ec2_create_actions = [
    "CreateVpc",
    "CreateSubnet",
    "CreateInternetGateway",
    "CreateRouteTable",
    "CreateSecurityGroup",
    "AuthorizeSecurityGroupIngress",
    "AuthorizeSecurityGroupEgress",
  ]

  elb_arns = [
    "${local.svc_arn["elasticloadbalancing"]}:loadbalancer/app/${local.name}-*/*",
    "${local.svc_arn["elasticloadbalancing"]}:targetgroup/${local.name}-*/*",
    "${local.svc_arn["elasticloadbalancing"]}:listener/app/${local.name}-*/*/*",
    "${local.svc_arn["elasticloadbalancing"]}:listener-rule/app/${local.name}-*/*/*/*",
  ]
}

data "aws_iam_policy_document" "apply" {
  # State access (B18).
  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = local.state_list_prefixes
    }
  }

  statement {
    sid       = "StateReadWrite"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.state_arn]
  }

  statement {
    sid       = "StateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.lock_arn]
  }

  # EC2 has random IDs, so scope by tag (B14).
  statement {
    sid       = "Ec2Read"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"] # No resource-level support for Describe
  }

  # Creates carry the tags on the new resource (RequestTag). A parent that already exists must carry them too
  # (ResourceTag), so a child cannot be attached to a VPC that this lab does not own.
  statement {
    sid     = "Ec2CreateTopLevelTagged"
    effect  = "Allow"
    actions = ["ec2:CreateVpc", "ec2:CreateInternetGateway"]
    resources = [
      local.ec2_type_arn["vpc"],
      local.ec2_type_arn["internet-gateway"],
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [local.tag_project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Env"
      values   = [var.env]
    }
  }

  statement {
    sid     = "Ec2CreateChildTagged"
    effect  = "Allow"
    actions = ["ec2:CreateSubnet", "ec2:CreateRouteTable", "ec2:CreateSecurityGroup"]
    resources = [
      local.ec2_type_arn["subnet"],
      local.ec2_type_arn["route-table"],
      local.ec2_type_arn["security-group"],
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [local.tag_project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Env"
      values   = [var.env]
    }
  }

  statement {
    sid       = "Ec2CreateChildInTaggedVpc"
    effect    = "Allow"
    actions   = ["ec2:CreateSubnet", "ec2:CreateRouteTable", "ec2:CreateSecurityGroup"]
    resources = [local.ec2_type_arn["vpc"]]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.tag_project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Env"
      values   = [var.env]
    }
  }

  # Authorize* touches the security group (tags exist) and the new rule (no tags yet, only RequestTag is
  # available there). The rule statement carries no condition: it is useless without the gated group statement.
  statement {
    sid       = "Ec2AuthorizeRulesOnTaggedGroup"
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress"]
    resources = [local.ec2_type_arn["security-group"]]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.tag_project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Env"
      values   = [var.env]
    }
  }

  statement {
    sid       = "Ec2AuthorizeRuleResource"
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress"]
    resources = [local.ec2_type_arn["security-group-rule"]]
  }

  statement {
    sid     = "Ec2TagOnCreate"
    effect  = "Allow"
    actions = ["ec2:CreateTags"]
    resources = [for t in ["vpc", "subnet", "internet-gateway", "route-table", "security-group", "security-group-rule"] :
    local.ec2_type_arn[t]]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = local.ec2_create_actions
    }
  }

  statement {
    sid    = "Ec2ManageTagged"
    effect = "Allow"
    actions = [
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:ReplaceRoute",
      "ec2:DeleteRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:DeleteSecurityGroup",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = [local.ec2_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.tag_project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Env"
      values   = [var.env]
    }
  }

  # The provider calls this when it creates an ALB with security groups. Tag-scoped, no wildcard action.
  statement {
    sid       = "Ec2ValidateSgQuotasOnTaggedGroup"
    effect    = "Allow"
    actions   = ["ec2:ValidateSecurityGroupQuotasForInterface"]
    resources = ["${local.svc_arn["ec2"]}:security-group/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.tag_project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Env"
      values   = [var.env]
    }
  }

  # ELB calls this with the caller's identity when it creates a load balancer. Its only resource type is vpc.
  statement {
    sid       = "Ec2SgsForTaggedVpc"
    effect    = "Allow"
    actions   = ["ec2:GetSecurityGroupsForVpc"]
    resources = [local.ec2_type_arn["vpc"]]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.tag_project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Env"
      values   = [var.env]
    }
  }

  statement {
    sid       = "ElbRead"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:Describe*"]
    resources = ["*"] # No resource-level support for Describe
  }

  statement {
    sid    = "ElbManage"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyListenerAttributes",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = local.elb_arns
  }

  statement {
    sid    = "EcsCluster"
    effect = "Allow"
    actions = [
      "ecs:CreateCluster",
      "ecs:DeleteCluster",
      "ecs:DescribeClusters",
      "ecs:UpdateCluster",
      "ecs:UpdateClusterSettings",
      "ecs:PutClusterCapacityProviders",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:ListTagsForResource",
    ]
    resources = ["${local.svc_arn["ecs"]}:cluster/${local.name}-*"]
  }

  statement {
    sid    = "EcsService"
    effect = "Allow"
    actions = [
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:DeleteService",
      "ecs:DescribeServices",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:ListTagsForResource",
    ]
    resources = ["${local.svc_arn["ecs"]}:service/${local.resource_names.ecs_cluster}/*"]
  }

  # Cost guard: task size is capped on registration (B18).
  statement {
    sid       = "EcsTaskDefRegister"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["${local.svc_arn["ecs"]}:task-definition/${local.name}-*:*"]

    condition {
      test     = "NumericLessThanEquals"
      variable = "ecs:task-cpu"
      values   = ["512"]
    }

    condition {
      test     = "NumericLessThanEquals"
      variable = "ecs:task-memory"
      values   = ["1024"]
    }
  }

  statement {
    sid       = "EcsTaskDefTags"
    effect    = "Allow"
    actions   = ["ecs:TagResource", "ecs:ListTagsForResource"]
    resources = ["${local.svc_arn["ecs"]}:task-definition/${local.name}-*:*"]
  }

  statement {
    sid       = "EcsTaskDefUnscoped"
    effect    = "Allow"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:DeregisterTaskDefinition"]
    resources = ["*"] # No resource-level support
  }

  statement {
    sid    = "Ecr"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:PutImageScanningConfiguration",
      "ecr:PutImageTagMutability",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:DeleteRepositoryPolicy",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:ListTagsForResource",
    ]
    resources = [local.ecr_repo_pattern]
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:TagLogGroup",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
    ]
    resources = local.log_group_arns
  }

  statement {
    sid       = "LogsRead"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"] # No resource-level support
  }

  # Secret shells only: G1 denies reading or writing values.
  statement {
    sid    = "SecretShell"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:UpdateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]
    resources = [local.secret_pattern]
  }

  # Roles can only be created or changed with the boundary attached (B15).
  statement {
    sid    = "IamEcsRolesBounded"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
    ]
    resources = local.ecs_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid    = "IamEcsRolesRead"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = local.ecs_role_arns
  }

  statement {
    sid       = "PassEcsRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.ecs_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["${local.iam_arn}:role/aws-service-role/ecs.amazonaws.com/*", "${local.iam_arn}:role/aws-service-role/elasticloadbalancing.amazonaws.com/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
