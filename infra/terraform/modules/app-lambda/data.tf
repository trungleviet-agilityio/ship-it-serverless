data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ADR 0012 L3, Finding 6: a Lambda image function can only be created from an image that is already in a private
# repository of the same region. This lookup fails the plan ("no matching images") while the repository is empty:
# run App Deploy once (it pushes the image and stops green with a notice when the function does not exist yet),
# then apply. After the create the digest only seeds IMAGE_DIGEST and image_uri, which Terraform then ignores.
# Accepted risk: after a teardown and re-create, the function starts on the newest pushed image,
# which may be newer than the last released one, until the next release. The README re-create steps therefore run
# a release with a known-green SHA right after the apply.
data "aws_ecr_image" "app" {
  repository_name = local.names.ecr_repository
  most_recent     = true
}
