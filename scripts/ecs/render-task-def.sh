#!/usr/bin/env bash
# Turn the family's latest task definition into a RegisterTaskDefinition request that differs only in the
# container image and the tags (ADR 0005, F3, F4). Offline: reads a file, prints JSON on stdout.
#
# Terraform owns the shape, so the shape is validated, not copied blindly: unknown keys, and any drift in the
# user, the root filesystem, the environment (exactly APP_ENV=<env>), the log group, the /tmp volume, the roles, the
# secret and the size caps, fail with a named rule. The input holds ARNs with the account ID, so nothing from it is printed except
# key names and rule names. The names come from the environment (app_names in lib.sh).
#
# Usage: scripts/ecs/render-task-def.sh --env <env> <describe.json> <image@digest> <commit sha>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

usage="usage: scripts/ecs/render-task-def.sh --env <env> <describe.json> <image@digest> <commit sha>"
{ [ $# -eq 5 ] && [ "$1" = "--env" ]; } || die "$usage"
ENV="$2" input="$3" image="$4" sha="$5"
app_names

require_cmd jq "brew install jq"
[ -f "$input" ] || die "task definition file not found: $input"

image_re="^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/${REPOSITORY}@sha256:[0-9a-f]{64}\$"
printf '%s' "$image" | grep -Eq "$image_re" \
  || die "image argument must be <account>.dkr.ecr.<region>.amazonaws.com/${REPOSITORY}@sha256:<64 hex> (a tag or another repository is refused)"
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "commit sha must be 40 hex characters"

# Read-only keys of DescribeTaskDefinition (ADR 0005, Finding 6); the request keys live in lib.sh.
readonly_keys='["taskDefinitionArn","revision","status","requiresAttributes","compatibilities","registeredAt","registeredBy","deregisteredAt","deleteRequestedAt"]'
# Container keys, rule: a key must be in the schema AND not denied.
# Schema: every member of the ContainerDefinition shape (42 members) in botocore ecs/2014-11-13/service-2.json at
# commit 4cee49b4bc3f84b39b611583f6eba09e1de5fcc6 (boto/botocore, 2026-10-20), which mirrors
# https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_ContainerDefinition.html. A key outside it is a
# new API field: review it, then add it here. Refresh with:
#   jq -c '.shapes.ContainerDefinition.members | keys' service-2.json
schema_container_keys='["command","cpu","credentialSpecs","dependsOn","disableNetworking","dnsSearchDomains","dnsServers","dockerLabels","dockerSecurityOptions","entryPoint","environment","environmentFiles","essential","extraHosts","firelensConfiguration","healthCheck","hostname","image","interactive","links","linuxParameters","logConfiguration","memory","memoryReservation","mountPoints","name","portMappings","privileged","pseudoTerminal","readonlyRootFilesystem","repositoryCredentials","resourceRequirements","restartPolicy","secrets","startTimeout","stopTimeout","systemControls","ulimits","user","versionConsistency","volumesFrom","workingDirectory"]'
# Denied even though the schema has them: each widens what the container may do or where its secrets come from.
# Not listed here, with their own rules below: user (must be 10001:10001) and volumesFrom (empty array only).
denied_container_keys='["privileged","linuxParameters","entryPoint","command","environmentFiles","repositoryCredentials","dockerSecurityOptions","links"]'

jq -e 'type == "object"' "$input" >/dev/null 2>&1 || die "task definition file is not a JSON object"

# First failing rule wins. Messages carry rule names and key names only, never values from the input.
problem="$(jq -r --argjson req "$REQUEST_KEYS_JSON" --argjson ro "$readonly_keys" --argjson schema "$schema_container_keys" --argjson denied "$denied_container_keys" \
  --arg env "$ENV" --arg exec_role "$EXEC_ROLE" --arg task_role "$TASK_ROLE" --arg secret "$SECRET_ID" --arg log_group "$LOG_GROUP" \
  --argjson cpu_max "$TASK_CPU_MAX" --argjson mem_max "$TASK_MEMORY_MAX" '
  (.taskDefinition // .) as $t
  | ($t.containerDefinitions // []) as $c
  | ($c[0] // {}) as $c0
  | [
      (($t | keys) - $req - $ro | if length > 0 then "unknown top-level key: " + join(", ") + " (new API field; review it before deploying)" else null end),
      (if ($c | length) != 1 then "task definition must have exactly one container" else null end),
      (if $c0.name != "app" then "the container must be named app" else null end),
      (($c0 | keys) - $schema | if length > 0 then "unknown container key: " + join(", ") + " (new API field; review it before deploying)" else null end),
      (($c0 | keys) - ($c0 | keys - $denied) | if length > 0 then "denied container key: " + join(", ") + " (Terraform does not set it; merge and apply the infra change first)" else null end),
      (if ($c0.volumesFrom // []) != [] then "denied container key: volumesFrom (only an empty array is allowed)" else null end),
      (if $c0.user != "10001:10001" then "the container user must be 10001:10001" else null end),
      (if $c0.readonlyRootFilesystem != true then "readonlyRootFilesystem must be true" else null end),
      (if ($c0.environment // []) != [{name: "APP_ENV", value: $env}] then "environment must be exactly APP_ENV=" + $env + " (a hand-made revision is never promoted)" else null end),
      (if ($c0.logConfiguration.logDriver // "") != "awslogs" or ($c0.logConfiguration.options["awslogs-group"] // "") != $log_group
        then "logConfiguration must be awslogs with the group " + $log_group else null end),
      (if ($c0.mountPoints // [] | map({sourceVolume, containerPath, readOnly: (.readOnly // false)}))
            != [{sourceVolume: "tmp", containerPath: "/tmp", readOnly: false}]
          or ($t.volumes // [] | map(.name)) != ["tmp"]
        then "mountPoints and volumes must be exactly the /tmp volume (name tmp, writable)" else null end),
      (if ($t.cpu // null) == null then "task-level cpu is missing" elif ($t.cpu | tonumber) > $cpu_max then "task-level cpu is above " + ($cpu_max | tostring) else null end),
      (if ($t.memory // null) == null then "task-level memory is missing" elif ($t.memory | tonumber) > $mem_max then "task-level memory is above " + ($mem_max | tostring) else null end),
      (if (($t.executionRoleArn // "") | endswith("role/" + $exec_role)) | not then "executionRoleArn must end in role/" + $exec_role else null end),
      (if (($t.taskRoleArn // "") | endswith("role/" + $task_role)) | not then "taskRoleArn must end in role/" + $task_role else null end),
      (if (($c0.secrets // []) | length) != 1
          or $c0.secrets[0].name != "APP_API_KEY"
          or (($c0.secrets[0].valueFrom // "") | test("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:" + $secret + "-[A-Za-z0-9]{6}$") | not)
        then "secrets must be exactly APP_API_KEY from the secret " + $secret else null end)
    ]
  | map(select(. != null)) | .[0] // ""
' "$input")" || die "could not read the task definition file"
[ -z "$problem" ] || die "render refused: $problem"

jq --arg image "$image" --arg sha "$sha" --arg env "$ENV" --argjson req "$REQUEST_KEYS_JSON" '
  (.taskDefinition // .)
  | with_entries(select(.key as $k | $req | index($k)))
  | .containerDefinitions[0].image = $image
  | .tags = [
      {key: "Project", value: "ship-it-safely"},
      {key: "Env", value: $env},
      {key: "ManagedBy", value: "app-deploy"},
      {key: "GitSha", value: $sha}
    ]
' "$input"
