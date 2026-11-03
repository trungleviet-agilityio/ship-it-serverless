# State bucket hardening (B8, B9).
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

run "bucket_identity" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "sis-dev-tfstate-123456789012-ap-southeast-1-an"
    error_message = "bucket name must follow the account-regional pattern"
  }

  assert {
    condition     = aws_s3_bucket.state.bucket_namespace == "account-regional" && aws_s3_bucket.state.force_destroy == false
    error_message = "account-regional namespace and force_destroy false"
  }
}

run "bucket_hardening" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "versioning must be Enabled"
  }

  assert {
    condition = (
      one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
      && contains(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).blocked_encryption_types, "SSE-C")
    )
    error_message = "SSE-S3 with SSE-C blocked"
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls
      && aws_s3_bucket_public_access_block.state.block_public_policy
      && aws_s3_bucket_public_access_block.state.ignore_public_acls
      && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "all four public access block flags must be true"
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ownership must be BucketOwnerEnforced"
  }
}

run "tls_only_policy" {
  command = plan

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.state_tls.statement : (
        s.effect == "Deny"
        && contains(s.actions, "s3:*")
        && anytrue([
          for c in s.condition : c.test == "Bool" && c.variable == "aws:SecureTransport" && contains(c.values, "false")
        ])
      )
    ])
    error_message = "bucket policy must deny s3:* when aws:SecureTransport is false"
  }
}

run "lifecycle" {
  command = plan

  assert {
    condition = (
      one(one(aws_s3_bucket_lifecycle_configuration.state.rule).noncurrent_version_expiration).noncurrent_days == 90
      && one(one(aws_s3_bucket_lifecycle_configuration.state.rule).noncurrent_version_expiration).newer_noncurrent_versions == 10
      && one(one(aws_s3_bucket_lifecycle_configuration.state.rule).abort_incomplete_multipart_upload).days_after_initiation == 7
    )
    error_message = "noncurrent 90 days keeping 10, multipart abort after 7 days"
  }
}
