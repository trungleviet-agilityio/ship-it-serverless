# Committed on purpose (FR-6): environments differ only through this file. No account ID here;
# aws_account_id comes from TF_VAR_aws_account_id (CI) or a gitignored *.auto.tfvars.
aws_region = "ap-southeast-1"
prefix     = "sls"
env        = "dev"

# Function shape (ADR 0012 L1). The image is not set here: the function is created from the newest image in the
# bootstrap repository, and App Deploy owns the image after that (L3).
memory_mb          = 512
timeout_s          = 10
log_retention_days = 7

# Cost ceiling (ADR 0012 L2, L10): stage throttling works in any account.
api_throttle_rate_limit  = 5
api_throttle_burst_limit = 10

# Optional second cap. Lambda refuses a reservation that leaves the account fewer than 100 unreserved, so keep it
# unset while the account concurrency quota is low (some new accounts have 10, ADR 0012 Finding 10).
# reserved_concurrency = 5
