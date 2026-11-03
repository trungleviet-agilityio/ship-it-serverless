# NFR-7 stretch: the trail, its bucket, and the alert on unexpected GitHub OIDC assumptions (ADR 0007 S22 to S27).
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

run "trail_is_management_only" {
  command = plan

  assert {
    condition = (
      length(aws_cloudtrail.this) == 1
      && aws_cloudtrail.this[0].name == "sis-dev-trail"
      && aws_cloudtrail.this[0].is_multi_region_trail
      && aws_cloudtrail.this[0].include_global_service_events
      && aws_cloudtrail.this[0].enable_log_file_validation
    )
    error_message = "trail must be multi-region, include global events and validate log files"
  }

  assert {
    condition = (
      aws_cloudtrail.this[0].cloud_watch_logs_group_arn == null
      && aws_cloudtrail.this[0].cloud_watch_logs_role_arn == null
      && aws_cloudtrail.this[0].kms_key_id == null
      && length(aws_cloudtrail.this[0].event_selector) == 0
      && length(aws_cloudtrail.this[0].advanced_event_selector) == 0
    )
    error_message = "no CloudWatch Logs delivery, no KMS key, no data event selectors (cost)"
  }
}

run "trail_bucket_hardening" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket.trail[0].bucket == "sis-dev-cloudtrail-123456789012-ap-southeast-1-an"
      && aws_s3_bucket.trail[0].bucket_namespace == "account-regional"
      && aws_s3_bucket.trail[0].force_destroy
    )
    error_message = "account-regional bucket name and force_destroy true (ADR 0007 Q9)"
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.trail[0].block_public_acls
      && aws_s3_bucket_public_access_block.trail[0].block_public_policy
      && aws_s3_bucket_public_access_block.trail[0].ignore_public_acls
      && aws_s3_bucket_public_access_block.trail[0].restrict_public_buckets
      && one(aws_s3_bucket_ownership_controls.trail[0].rule).object_ownership == "BucketOwnerEnforced"
    )
    error_message = "public access block and BucketOwnerEnforced"
  }

  assert {
    condition = (
      one(aws_s3_bucket_server_side_encryption_configuration.trail[0].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
      && contains(one(aws_s3_bucket_server_side_encryption_configuration.trail[0].rule).blocked_encryption_types, "SSE-C")
    )
    error_message = "SSE-S3 with SSE-C blocked"
  }

  assert {
    condition = (
      one(one(aws_s3_bucket_lifecycle_configuration.trail[0].rule).expiration).days == 30
      && one(aws_s3_bucket_lifecycle_configuration.trail[0].rule).status == "Enabled"
    )
    error_message = "trail logs expire after 30 days"
  }
}

run "trail_bucket_policy" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.trail_bucket.statement : (
        s.sid == "DenyInsecureTransport"
        ? (s.effect == "Deny" && anytrue([for c in s.condition : c.variable == "aws:SecureTransport" && contains(c.values, "false")]))
        : (
          s.effect == "Allow"
          && toset([for p in s.principals : p.type]) == toset(["Service"])
          && toset(flatten([for p in s.principals : p.identifiers])) == toset(["cloudtrail.amazonaws.com"])
          && anytrue([
            for c in s.condition : c.variable == "aws:SourceArn" && c.test == "StringEquals"
            && toset(c.values) == toset(["arn:aws:cloudtrail:ap-southeast-1:123456789012:trail/sis-dev-trail"])
          ])
        )
      )
    ])
    error_message = "every Allow must be for cloudtrail.amazonaws.com and carry aws:SourceArn equal to the trail ARN"
  }

  assert {
    condition = toset(flatten([
      for s in data.aws_iam_policy_document.trail_bucket.statement : s.actions if s.effect == "Allow"
    ])) == toset(["s3:GetBucketAcl", "s3:PutObject"])
    error_message = "the trail may only check the bucket ACL and put objects"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.trail_bucket.statement : (
        contains(s.actions, "s3:PutObject")
        && toset(s.resources) == toset(["${local.trail_bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"])
        && anytrue([for c in s.condition : c.variable == "s3:x-amz-acl" && contains(c.values, "bucket-owner-full-control")])
      )
    ])
    error_message = "PutObject must be limited to AWSLogs/<account>/* and bucket-owner-full-control"
  }
}

run "alert_rule_pattern" {
  command = plan

  assert {
    condition     = aws_cloudwatch_event_rule.oidc_unexpected.state == "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"
    error_message = "AssumeRoleWithWebIdentity is a read-only event: the rule must opt in to all management events"
  }

  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.oidc_unexpected.event_pattern).source == ["aws.sts"]
      && jsondecode(aws_cloudwatch_event_rule.oidc_unexpected.event_pattern).detail.eventName == ["AssumeRoleWithWebIdentity"]
    )
    error_message = "the rule must match STS AssumeRoleWithWebIdentity"
  }

  assert {
    condition = (
      length(jsondecode(aws_cloudwatch_event_rule.oidc_unexpected.event_pattern).detail["$or"]) == 2
      && jsondecode(aws_cloudwatch_event_rule.oidc_unexpected.event_pattern).detail["$or"][0].errorCode == [{ exists = true }]
    )
    error_message = "a refusal must alert through errorCode exists"
  }

  assert {
    condition = (
      toset(jsondecode(aws_cloudwatch_event_rule.oidc_unexpected.event_pattern).detail["$or"][1].userIdentity.userName[0]["anything-but"]) == toset([
        "repo:trungleviet-agilityio@111/ship-it-safely@222:pull_request",
        "repo:trungleviet-agilityio@111/ship-it-safely@222:environment:dev",
      ])
      && length(jsondecode(aws_cloudwatch_event_rule.oidc_unexpected.event_pattern).detail["$or"][1].userIdentity.userName[0]["anything-but"]) == 2
    )
    error_message = "a success with any subject other than the two trusted ones must alert (distinct subs, no duplicates)"
  }

  assert {
    condition     = !strcontains(aws_cloudwatch_event_rule.oidc_unexpected.event_pattern, local.account_id)
    error_message = "the pattern must not contain the account ID"
  }

  assert {
    condition     = aws_cloudwatch_event_target.security_alerts.rule == "sis-dev-oidc-unexpected"
    error_message = "the target must hang off the alert rule"
  }

  assert {
    condition = (
      length(aws_cloudwatch_event_target.security_alerts.input_transformer) == 1
      && aws_cloudwatch_event_target.security_alerts.input_transformer[0].input_paths == tomap({
        time    = "$.detail.eventTime"
        region  = "$.detail.awsRegion"
        sub     = "$.detail.userIdentity.userName"
        role    = "$.detail.requestParameters.roleArn"
        session = "$.detail.requestParameters.roleSessionName"
        error   = "$.detail.errorCode"
        ip      = "$.detail.sourceIPAddress"
      })
    )
    error_message = "the alert email is plain lines (time, region, error, role, sub, session, source IP), not the raw event"
  }

  assert {
    condition = alltrue([
      for line in split("\n", trimspace(aws_cloudwatch_event_target.security_alerts.input_transformer[0].input_template)) :
      can(regex("^\"[^\"]*\"$", line))
    ])
    error_message = "every template line must be one double-quoted string (EventBridge multi-line text), with no inner quotes"
  }

  assert {
    condition = alltrue([
      for v in ["time", "region", "error", "role", "sub", "session", "ip"] :
      strcontains(aws_cloudwatch_event_target.security_alerts.input_transformer[0].input_template, "<${v}>")
    ])
    error_message = "the template must use every input path"
  }
}

run "topic_policy_and_subscription" {
  command = plan

  assert {
    condition = (
      length(data.aws_iam_policy_document.security_alerts.statement) == 1
      && alltrue([
        for s in data.aws_iam_policy_document.security_alerts.statement : (
          s.effect == "Allow"
          && toset(s.actions) == toset(["sns:Publish"])
          && toset(flatten([for p in s.principals : p.identifiers])) == toset(["events.amazonaws.com"])
          && anytrue([
            for c in s.condition : c.variable == "aws:SourceArn" && toset(c.values) == toset([aws_cloudwatch_event_rule.oidc_unexpected.arn])
          ])
        )
      ])
    )
    error_message = "only events.amazonaws.com may publish, and only for the rule ARN"
  }

  assert {
    condition = (
      aws_sns_topic.security_alerts.name == "sis-dev-security-alerts"
      && aws_sns_topic.security_alerts.kms_master_key_id == null
      && aws_sns_topic_subscription.security_email.protocol == "email"
      && aws_sns_topic_subscription.security_email.endpoint == var.budget_email
    )
    error_message = "email subscription to budget_email on an unencrypted topic (EventBridge cannot use the managed key)"
  }
}

run "existing_trail_keeps_the_rule" {
  command = plan

  variables {
    create_trail = false
  }

  assert {
    condition = (
      length(aws_cloudtrail.this) == 0
      && length(aws_s3_bucket.trail) == 0
      && length(aws_s3_bucket_policy.trail) == 0
    )
    error_message = "create_trail = false must create no trail and no trail bucket"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.oidc_unexpected.name == "sis-dev-oidc-unexpected" && aws_sns_topic.security_alerts.name == "sis-dev-security-alerts"
    error_message = "the alert rule and topic stay even without a trail"
  }
}
