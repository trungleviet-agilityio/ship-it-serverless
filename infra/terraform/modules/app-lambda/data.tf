data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ADR 0012 L3, Finding 6: a Lambda image function can only be created from an image that is already in a private
# repository of the same region. This lookup fails the plan ("no matching images") while the repository is empty:
# run App Deploy once (it pushes the image and stops green with a notice when the function does not exist yet),
# then apply. After the create the digest only seeds IMAGE_DIGEST and image_uri, which Terraform then ignores.
data "aws_ecr_image" "app" {
  repository_name = local.names.ecr_repository
  most_recent     = true
}
