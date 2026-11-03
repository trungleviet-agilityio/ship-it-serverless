# NFR-7 stretch (ADR 0007 S8, S22 to S27): a management-event trail and an EventBridge rule that emails
# an alert when a GitHub OIDC assumption is refused or succeeds with an unexpected subject.
# About 0 USD a month: the first trail copy is free, EventBridge ingests management events for free,
# and there is no CloudWatch Logs delivery, KMS key or CloudTrail role.

locals {
  trail_name        = "${local.name}-trail"
  trail_bucket_name = "${local.name}-cloudtrail-${local.account_id}-${local.region}-an"
  trail_bucket_arn  = "arn:${local.partition}:s3:::${local.trail_bucket_name}"
  # Built from names, not from aws_cloudtrail.this: the bucket policy must exist before the trail can be created.
  trail_arn  = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${local.trail_name}"
  topic_name = "${local.name}-security-alerts"
  rule_name  = "${local.name}-oidc-unexpected"

  # The subjects a healthy pipeline presents. They hold owner and repo IDs, never the account ID.
  expected_subs = distinct([for t in local.trust : t.sub])
}

# Trail bucket (S22, S23)

resource "aws_s3_bucket" "trail" {
  count = var.create_trail ? 1 : 0

  bucket = local.trail_bucket_name
  # Only this account can create names in its account-regional namespace (B8).
  bucket_namespace = "account-regional"
  # Lab teardown in one step; event history keeps 90 days anyway (ADR 0007 Q9).
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count = var.create_trail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  rule {
    blocked_encryption_types = ["SSE-C"]

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count = var.create_trail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "trail" {
  count = var.create_trail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count = var.create_trail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id

  rule {
    id     = "expire-trail-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"] # Deny only: widens protection
    resources = [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "CloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.trail_bucket_arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.trail_bucket_arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count = var.create_trail ? 1 : 0

  bucket = aws_s3_bucket.trail[0].id
  policy = data.aws_iam_policy_document.trail_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

# Trail (S24). Management events only: no CloudWatch Logs, no KMS, no data events.
# Skipped when the account already has a trail, so the lab never pays for a second copy (Q2).
resource "aws_cloudtrail" "this" {
  count = var.create_trail ? 1 : 0

  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.trail]
}

# Alert topic and rule (S25 to S27)

# No KMS: EventBridge cannot publish to a topic that uses the AWS-managed SNS key, and a CMK costs money.
resource "aws_sns_topic" "security_alerts" {
  name = local.topic_name
}

data "aws_iam_policy_document" "security_alerts" {
  statement {
    sid       = "EventBridgePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.oidc_unexpected.arn]
    }
  }

  # ADR 0012 L10: the app alarms of envs/<env> (Lambda Errors and Throttles, HTTP API 5xx) notify this topic.
  # CloudWatch publishes as its service principal; the conditions limit it to this env's alarms in this account
  # (confused deputy protection). The CI roles still cannot touch the topic (G6).
  statement {
    sid       = "CloudWatchAlarmPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["${local.svc_arn["cloudwatch"]}:alarm:${local.name}-*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts.json
}

# The recipient confirms the subscription by email once.
resource "aws_sns_topic_subscription" "security_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_email
}

# AssumeRoleWithWebIdentity is logged as a read-only event, so the rule must opt in to read-only management
# events. A refusal alerts through errorCode; a success with a subject outside the trust alerts through
# anything-but.
resource "aws_cloudwatch_event_rule" "oidc_unexpected" {
  name        = local.rule_name
  description = "GitHub OIDC assumption refused, or granted to an unexpected subject"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.sts"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AssumeRoleWithWebIdentity"]
      "$or" = [
        { errorCode = [{ exists = true }] },
        { userIdentity = { userName = [{ "anything-but" = local.expected_subs }] } },
      ]
    }
  })
}

# A few plain lines instead of the raw event JSON (ADR 0007 checkpoint A5); the full event stays in CloudTrail.
# Each line is its own quoted string, which is how EventBridge emits multi-line text. A path missing from the event
# (errorCode on a success) creates no variable, so that line ends blank.
resource "aws_cloudwatch_event_target" "security_alerts" {
  rule = aws_cloudwatch_event_rule.oidc_unexpected.name
  arn  = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      time    = "$.detail.eventTime"
      region  = "$.detail.awsRegion"
      sub     = "$.detail.userIdentity.userName"
      role    = "$.detail.requestParameters.roleArn"
      session = "$.detail.requestParameters.roleSessionName"
      error   = "$.detail.errorCode"
      ip      = "$.detail.sourceIPAddress"
    }
    input_template = <<-EOT
      "GitHub OIDC alert from rule <aws.events.rule-name>: an AssumeRoleWithWebIdentity call was refused, or granted to a subject outside the trust."
      "Time: <time> (<region>)"
      "Error code (blank: the role was granted, check the trust): <error>"
      "Role: <role>"
      "Subject (sub): <sub>"
      "Session: <session>"
      "Source IP: <ip>"
      "Full event: CloudTrail event history, event name AssumeRoleWithWebIdentity."
    EOT
  }
}
