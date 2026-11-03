#!/usr/bin/env bash
# Print a derived name. One entry point for the three name lookups (the derivations live in lib.sh).
#
#   scripts/names.sh image <commit sha>   the local image name for a commit (image_name)
#   scripts/names.sh app                  the resource names of ENV (default dev) as KEY=value lines, ready to
#                                         append to $GITHUB_ENV (app_names): ENV=dev scripts/names.sh app >> "$GITHUB_ENV"
#   scripts/names.sh env-root             the Terraform root of ENV (default dev), validated: infra/terraform/envs/<env>.
#                                         tf_dir="$(scripts/names.sh env-root)"; echo "TF_DIR=${tf_dir}" >> "$GITHUB_ENV"
#                                         (assign first: inside echo "...$(...)" a failure would not fail the step)
#   scripts/names.sh gha-role <kind>      the name of the plan, apply or deploy role of ENV (default dev), from
#                                         project.env: role="$(ENV=dev scripts/names.sh gha-role plan)"
#   scripts/names.sh role                 the name of the AWS role the job assumed (never the session name, which
#                                         carries the run ID), for a job summary. Exits 1 when no role is assumed;
#                                         a summary step turns that into "not assumed". Needs the AWS CLI.
#                                         role="$(scripts/names.sh role 2>/dev/null)" || role="not assumed"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: scripts/names.sh image <commit sha> | ENV=dev scripts/names.sh app | ENV=dev scripts/names.sh env-root | ENV=dev scripts/names.sh gha-role <kind> | scripts/names.sh role"
[ $# -ge 1 ] || die "$usage"
kind="$1"
shift

case "$kind" in
  image)
    [ $# -eq 1 ] || die "usage: scripts/names.sh image <commit sha>"
    image_name "$1"
    echo
    ;;
  app)
    [ $# -eq 0 ] || die "usage: ENV=dev scripts/names.sh app"
    app_names
    printf '%s=%s\n' CLUSTER "$CLUSTER" SERVICE "$SERVICE" FAMILY "$FAMILY" REPOSITORY "$REPOSITORY"
    ;;
  env-root)
    [ $# -eq 0 ] || die "usage: ENV=dev scripts/names.sh env-root"
    require_env
    env_root "$ENV"
    echo
    ;;
  gha-role)
    [ $# -eq 1 ] || die "usage: ENV=dev scripts/names.sh gha-role <plan|apply|deploy>"
    gha_role_name "$1"
    echo
    ;;
  role)
    [ $# -eq 0 ] || die "usage: scripts/names.sh role"
    require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
    assumed_role_name || die "the credentials are not an assumed role"
    ;;
  *) die "$usage" ;;
esac
