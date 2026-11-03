#!/usr/bin/env bash
# Self-tests of the CI helper scripts: the task definition render.
# Run by scripts/ci/selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- render-task-def.sh (fixtures built at run time; 123456789012 is the AWS documentation account).
# td-good.json mimics describe-task-definition for the Terraform revision, with the defaults ECS adds.
cat >"$tmp/td-good.json" <<EOF
{
  "taskDefinitionArn": "arn:aws:ecs:ap-southeast-1:${acct}:task-definition/sis-dev-app:7",
  "family": "sis-dev-app", "revision": 7, "status": "ACTIVE",
  "requiresAttributes": [{"name": "com.amazonaws.ecs.capability.logging-driver.awslogs"}, {"name": "ecs.capability.execution-role-awslogs"}, {"name": "ecs.capability.secrets.asm.environment-variables"}], "compatibilities": ["FARGATE"],
  "registeredAt": "2026-10-26T00:00:00Z", "registeredBy": "arn:aws:sts::${acct}:assumed-role/x/y",
  "deregisteredAt": null, "deleteRequestedAt": null,
  "taskRoleArn": "arn:aws:iam::${acct}:role/sis-dev-ecs-task",
  "executionRoleArn": "arn:aws:iam::${acct}:role/sis-dev-ecs-exec",
  "networkMode": "awsvpc", "cpu": "256", "memory": "512",
  "requiresCompatibilities": ["FARGATE"],
  "runtimePlatform": {"operatingSystemFamily": "LINUX", "cpuArchitecture": "X86_64"},
  "volumes": [{"name": "tmp", "host": {}}],
  "tags": [{"key": "ManagedBy", "value": "terraform"}],
  "containerDefinitions": [{
    "name": "app", "image": "public.ecr.aws/docker/library/python:3.13-slim@sha256:${digest}",
    "cpu": 0, "essential": true, "user": "10001:10001", "readonlyRootFilesystem": true,
    "portMappings": [{"containerPort": 8080, "hostPort": 8080, "protocol": "tcp"}],
    "mountPoints": [{"sourceVolume": "tmp", "containerPath": "/tmp", "readOnly": false}],
    "volumesFrom": [], "systemControls": [], "versionConsistency": "enabled",
    "environment": [{"name": "APP_ENV", "value": "dev"}],
    "logConfiguration": {"logDriver": "awslogs", "options": {"awslogs-group": "/ecs/sis-dev-app", "awslogs-region": "ap-southeast-1", "awslogs-stream-prefix": "app"}},
    "secrets": [{"name": "APP_API_KEY", "valueFrom": "arn:aws:secretsmanager:ap-southeast-1:${acct}:secret:sis/dev/app-api-key-AbC123"}]
  }]
}
EOF
render() { "$ROOT/scripts/ecs/render-task-def.sh" --env dev "$1" "$image" "$commit"; }
# mutate <name> <jq filter>: a copy of the good fixture with one thing broken.
mutate() { jq "$2" "$tmp/td-good.json" >"$tmp/td-$1.json"; }

render "$tmp/td-good.json" >"$tmp/td-out.json" 2>/dev/null || die "selftest: good task definition rejected"
jq -e --arg image "$image" --arg sha "$commit" --arg acct "$acct" --argjson req "$REQUEST_KEYS_JSON" '
  (keys - $req) == []
  and (has("deleteRequestedAt") | not) and (has("revision") | not) and (has("taskDefinitionArn") | not)
  and .containerDefinitions[0].image == $image
  and (.tags | map({(.key): .value}) | add) == {"Project": "ship-it-safely", "Env": "dev", "ManagedBy": "app-deploy", "GitSha": $sha}
  and .cpu == "256" and .memory == "512" and .volumes == [{"name": "tmp", "host": {}}]
  and .containerDefinitions[0].secrets[0].valueFrom == "arn:aws:secretsmanager:ap-southeast-1:\($acct):secret:sis/dev/app-api-key-AbC123"
  and .executionRoleArn == "arn:aws:iam::\($acct):role/sis-dev-ecs-exec"
' "$tmp/td-out.json" >/dev/null || die "selftest: rendered task definition is not as expected"
ok "render keeps the shape and sets image and tags"

mutate cmd '.containerDefinitions[0].command = ["sh"]'
expect_fail "render with a command" "denied container key: command" render "$tmp/td-cmd.json"
mutate ep '.containerDefinitions[0].entryPoint = ["sh"]'
expect_fail "render with an entryPoint" "denied container key: entryPoint" render "$tmp/td-ep.json"
mutate two '.containerDefinitions += [.containerDefinitions[0]]'
expect_fail "render with two containers" "exactly one container" render "$tmp/td-two.json"
mutate name '.containerDefinitions[0].name = "web"'
expect_fail "render with another container name" "named app" render "$tmp/td-name.json"
mutate key '.fooBar = 1'
expect_fail "render with an unknown top-level key" "unknown top-level key: fooBar" render "$tmp/td-key.json"
mutate nocpu 'del(.cpu)'
expect_fail "render without task-level cpu" "cpu is missing" render "$tmp/td-nocpu.json"
mutate bigmem '.memory = "2048"'
expect_fail "render with memory 2048" "memory is above 1024" render "$tmp/td-bigmem.json"
mutate bigcpu '.cpu = "1024"'
expect_fail "render with cpu 1024" "cpu is above 512" render "$tmp/td-bigcpu.json"
mutate exec '.executionRoleArn |= sub("sis-dev-ecs-exec"; "other")'
expect_fail "render with the wrong exec role" "role/sis-dev-ecs-exec" render "$tmp/td-exec.json"
mutate task '.taskRoleArn |= sub("sis-dev-ecs-task"; "other")'
expect_fail "render with the wrong task role" "role/sis-dev-ecs-task" render "$tmp/td-task.json"
mutate secret '.containerDefinitions[0].secrets[0].valueFrom |= sub("app-api-key"; "other-key")'
expect_fail "render with another secret" "secrets must be exactly APP_API_KEY" render "$tmp/td-secret.json"
mutate secret2 '.containerDefinitions[0].secrets += [.containerDefinitions[0].secrets[0]]'
expect_fail "render with two secrets" "secrets must be exactly APP_API_KEY" render "$tmp/td-secret2.json"
# One fixture per rule on the container shape Terraform owns (ADR 0005, M1).
mutate ckey '.containerDefinitions[0].fooBar = true'
expect_fail "render with an unknown container key" "unknown container key: fooBar" render "$tmp/td-ckey.json"
# Every denied key is refused, even though the ECS schema has it (the list is read from the script).
denied_keys="$(sed -n "s/^denied_container_keys='\(.*\)'\$/\1/p" "$ROOT/scripts/ecs/render-task-def.sh" | jq -r '.[]')"
[ "$(printf '%s\n' "$denied_keys" | wc -l | tr -d ' ')" -ge 8 ] || die "selftest: could not read the denied container keys"
for k in $denied_keys; do
  mutate "deny-$k" ".containerDefinitions[0].$k = true"
  expect_fail "render with the denied key $k" "denied container key: $k" render "$tmp/td-deny-$k.json"
done
mutate vfrom '.containerDefinitions[0].volumesFrom = [{"sourceContainer": "other"}]'
expect_fail "render with a non-empty volumesFrom" "denied container key: volumesFrom" render "$tmp/td-vfrom.json"
# A schema key that is not denied is accepted.
mutate schemakey '.containerDefinitions[0].workingDirectory = "/"'
render "$tmp/td-schemakey.json" >/dev/null 2>&1 || die "selftest: a schema key that is not denied (workingDirectory) was refused"
mutate user '.containerDefinitions[0].user = "0:0"'
expect_fail "render with another user" "user must be 10001:10001" render "$tmp/td-user.json"
mutate nouser 'del(.containerDefinitions[0].user)'
expect_fail "render without a user" "user must be 10001:10001" render "$tmp/td-nouser.json"
mutate rw '.containerDefinitions[0].readonlyRootFilesystem = false'
expect_fail "render with a writable root" "readonlyRootFilesystem must be true" render "$tmp/td-rw.json"
mutate env2 '.containerDefinitions[0].environment += [{"name": "DEBUG", "value": "1"}]'
expect_fail "render with an extra environment variable" "environment must be exactly APP_ENV=dev" render "$tmp/td-env2.json"
mutate env0 '.containerDefinitions[0].environment = []'
expect_fail "render with no environment" "environment must be exactly APP_ENV=dev" render "$tmp/td-env0.json"
mutate envval '.containerDefinitions[0].environment[0].value = "prod"'
expect_fail "render with APP_ENV of another environment" "environment must be exactly APP_ENV=dev" render "$tmp/td-envval.json"
mutate envname '.containerDefinitions[0].environment[0].name = "app_env"'
expect_fail "render with a renamed APP_ENV" "environment must be exactly APP_ENV=dev" render "$tmp/td-envname.json"
mutate logg '.containerDefinitions[0].logConfiguration.options["awslogs-group"] = "/ecs/other"'
expect_fail "render with another log group" "logConfiguration must be awslogs with the group /ecs/sis-dev-app" render "$tmp/td-logg.json"
mutate logd '.containerDefinitions[0].logConfiguration.logDriver = "splunk"'
expect_fail "render with another log driver" "logConfiguration must be awslogs" render "$tmp/td-logd.json"
mutate mnt '.containerDefinitions[0].mountPoints[0].containerPath = "/data"'
expect_fail "render with another mount path" "exactly the /tmp volume" render "$tmp/td-mnt.json"
mutate mnt2 '.containerDefinitions[0].mountPoints += [{"sourceVolume": "tmp", "containerPath": "/var", "readOnly": false}]'
expect_fail "render with a second mount" "exactly the /tmp volume" render "$tmp/td-mnt2.json"
mutate vol '.volumes += [{"name": "data"}]'
expect_fail "render with a second volume" "exactly the /tmp volume" render "$tmp/td-vol.json"
mutate nocontainers '.containerDefinitions = []'
expect_fail "render with no containers" "exactly one container" render "$tmp/td-nocontainers.json"
# A task definition for another environment renders for that environment only.
sed 's/sis-dev/sis-prod/g; s#sis/dev#sis/prod#g; s/"value": "dev"/"value": "prod"/' "$tmp/td-good.json" >"$tmp/td-prod.json"
image_prod="${image/sis-dev-app/sis-prod-app}"
"$ROOT/scripts/ecs/render-task-def.sh" --env prod "$tmp/td-prod.json" "$image_prod" "$commit" 2>/dev/null \
  | jq -e '(.tags | map({(.key): .value}) | add).Env == "prod"' >/dev/null || die "selftest: the prod task definition was not rendered with Env prod"
expect_fail "render of the dev task definition for prod" "environment must be exactly APP_ENV=prod" \
  "$ROOT/scripts/ecs/render-task-def.sh" --env prod "$tmp/td-good.json" "$image_prod" "$commit"
expect_fail "render without --env" "usage:" "$ROOT/scripts/ecs/render-task-def.sh" "$tmp/td-good.json" "$image" "$commit"
expect_fail "render with an invalid env" "ENV must be lowercase" "$ROOT/scripts/ecs/render-task-def.sh" --env "../x" "$tmp/td-good.json" "$image" "$commit"
expect_fail "render with a tag instead of a digest" "image argument" \
  "$ROOT/scripts/ecs/render-task-def.sh" --env dev "$tmp/td-good.json" "${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app:latest" "$commit"
expect_fail "render with another repository" "image argument" \
  "$ROOT/scripts/ecs/render-task-def.sh" --env dev "$tmp/td-good.json" "${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/other@sha256:${digest}" "$commit"
expect_fail "render with a short commit" "40 hex" "$ROOT/scripts/ecs/render-task-def.sh" --env dev "$tmp/td-good.json" "$image" abc123
# A describe-task-definition response (wrapped in "taskDefinition") renders the same as the bare object.
jq '{taskDefinition: ., tags: []}' "$tmp/td-good.json" >"$tmp/td-wrapped.json"
render "$tmp/td-wrapped.json" 2>/dev/null | jq -e '.family == "sis-dev-app"' >/dev/null || die "selftest: wrapped describe output rejected"
