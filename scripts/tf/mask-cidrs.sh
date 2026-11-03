#!/usr/bin/env bash
# Hide the optional ALB ingress CIDRs from the log (ADR 0007 S35). The secret ALB_INGRESS_CIDRS (an environment secret
# for apply and destroy; the PR plan maps it from the repository secret ALB_INGRESS_CIDRS_<ENV>) is a JSON list; GitHub
# masks the whole string, but Terraform prints single elements, so each one is masked too.
# Prints workflow commands only: one ::add-mask:: per element, or a notice when the list is empty (the default).
# A value that is not a JSON list of strings fails without being printed.
#
# --require is for the apply (ADR 0008): an empty value fails, so a forgotten environment secret cannot open the ALB to
# 0.0.0.0/0 while the PR plan, which reads another secret, looked restricted. To be open on purpose, set the secret to
# ["0.0.0.0/0"]. The PR plan and the destroy do not pass it: unset means open there, and a destroy must always work.
#
# Usage: scripts/tf/mask-cidrs.sh [--require]        Env: CIDRS  the JSON list, or empty; ENV  names the environment in the message

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

require=0
case "${1:-}" in
  "") ;;
  --require) require=1; shift ;;
esac
[ $# -eq 0 ] || die "usage: scripts/tf/mask-cidrs.sh [--require] (reads CIDRS)"
require_cmd jq "install jq"

if [ -z "${CIDRS:-}" ]; then
  [ "$require" -eq 0 ] \
    || die "ALB_INGRESS_CIDRS is empty: set the environment secret ALB_INGRESS_CIDRS of the ${ENV:-target} environment to a JSON list of CIDRs, or to [\"0.0.0.0/0\"] to open the ALB on purpose"
  echo "::notice::ALB ingress: default 0.0.0.0/0"
  exit 0
fi

jq -e 'type == "array" and length > 0 and all(type == "string")' <<<"$CIDRS" >/dev/null 2>&1 \
  || die "ALB_INGRESS_CIDRS must be a JSON list of CIDR strings (the value is not shown)"
jq -r '.[] | "::add-mask::" + .' <<<"$CIDRS"
