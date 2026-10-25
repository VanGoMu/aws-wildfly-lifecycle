#!/usr/bin/env bash
# The shared validation: the ValidateService hook of CodeDeploy and the Validate document run this
# same file. It fails with the name of the check that failed, and always ends with one JSON line.
# shellcheck disable=SC2154  # APP_PORT, HEALTH_PATH and the versions come from instance.env
set -euo pipefail

# shellcheck source=remote/common.sh
source "$(dirname "$0")/common.sh"

# until_ok TRIES COMMAND…: every 2 s, for what takes a while after a (re)start.
until_ok() {
  local tries="$1" n
  shift
  for ((n = 0; n < tries; n++)); do
    "$@" && return 0
    sleep 2
  done
  return 1
}

has_release() { compgen -G "${WARS_DIR}/*.war" >/dev/null; }

# The health subsystem of WildFly 35 answers a list of checks (boot-errors, server-state,
# suspend-state, deployments-status) and an overall outcome, and 503 when one fails.
ready() {
  curl --fail --silent http://127.0.0.1:9990/health/ready \
    | jq -e 'all(.[]; .outcome == true)' >/dev/null
}

deployments() { cli_json '/deployment=*:read-resource(include-runtime=true)'; }

# Every WAR of release/wars deployed, enabled and OK, and no deployment FAILED.
check_wars() {
  local all war
  all=$(deployments) || return 1
  jq -e '[.result[]?.result.status] | all(. != "FAILED")' <<<"$all" >/dev/null || return 1
  for war in "$WARS_DIR"/*.war; do
    jq -e --arg name "${war##*/}" '.result[]? | select(.address[0].deployment == $name)
      | .result.enabled == true and .result.status == "OK"' <<<"$all" >/dev/null || return 1
  done
}

answers() { curl --fail --silent --output /dev/null "http://127.0.0.1:${APP_PORT}${HEALTH_PATH}"; }

property() {
  cli_json "/system-property=$1:read-attribute(name=value)" | jq -r '.result // empty'
}

report() {
  local release=null deps
  deps=$(deployments | jq -c '[.result[]? | {(.address[0].deployment): .result.status}] | add')
  [ -n "$deps" ] && [ "$deps" != null ] || deps='{}'
  if [ -f "$RELEASE_ENV" ]; then
    # shellcheck source=/dev/null
    release=$(set -a && source "$RELEASE_ENV" && jq -cn \
      '{key: env.BUNDLE_KEY, version: env.BUNDLE_VERSION, deploymentId: env.DEPLOYMENT_ID}')
  fi
  jq -cn \
    --arg status "$1" \
    --arg failed "${2:-}" \
    --arg wildfly "$WILDFLY_VERSION" \
    --arg agent "$CODEDEPLOY_AGENT_VERSION" \
    --arg ansibleCore "$ANSIBLE_CORE_VERSION" \
    --argjson release "$release" \
    --argjson deployments "$deps" \
    --arg configVersion "$(property lifecycle.config-version)" \
    --arg configFingerprint "$(property lifecycle.config-fingerprint)" \
    '$ARGS.named'
}

# run_check NAME COMMAND…: the JSON line and exit 1 on the first check that fails.
run_check() {
  local name="$1"
  shift
  "$@" && return 0
  echo "validation failed: ${name}" >&2
  report failed "$name"
  exit 1
}

main() {
  load_instance_env
  run_check service systemctl is-active --quiet wildfly
  run_check server-state wait_running
  run_check health-ready until_ok 30 ready
  if has_release; then
    run_check wars until_ok 15 check_wars
    run_check http until_ok 30 answers
  fi
  report ok
}

main "$@"
