locals {
  default_tags = {
    Project   = "ship-it-serverless"
    Env       = var.env
    ManagedBy = "terraform"
  }

  # The alert topic is created by bootstrap monitoring (<prefix>-<env>-security-alerts, ADR 0012 L10). Its ARN is
  # built from its name instead of a data "aws_sns_topic" lookup: that data source also lists the topic's tags, and
  # the guardrail G6 denies every sns action on this topic to the plan, apply and deploy roles. The bootstrap topic
  # policy lets CloudWatch publish for this env's alarms (CloudWatchAlarmPublish).
  alarm_topic_arn = "arn:${data.aws_partition.current.partition}:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.prefix}-${var.env}-security-alerts"
}
