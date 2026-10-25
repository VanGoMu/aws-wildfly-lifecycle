#!/usr/bin/env bash
# The local environment: the lifecycle with Docker Compose and without an AWS account. blue and
# green are amazonlinux:2023 containers with systemd that run what an instance runs
# (remote/install-wildfly.sh, the CodeDeploy agent in deploy-local mode, the Ansible playbook,
# validate.sh); nginx is the ALB, with its weighted listener and its test listener; k6 makes the
# traffic. This script plays the control plane: the steps of the Release and Switch runbooks, in
# their order, with files under build/local/ in place of S3, Parameter Store and Secrets Manager.
# docs/local-development.md tells what is the same as in AWS and what is simulated.
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${LIB}/common.sh"
# shellcheck source=lib/release.sh
source "${LIB}/release.sh"

ENV_NAME="${ENV_NAME:-local}"
COMPOSE_FILE="${ROOT_DIR}/local/compose.yml"
LOCAL_DIR="${ROOT_DIR}/build/local"
CACHE_DIR="${ROOT_DIR}/build/cache"
# S3, …/state, …/config and the secret, as files.
BUCKET_DIR="${LOCAL_DIR}/bucket"
STATE_DIR="${LOCAL_DIR}/state"
PARAMETERS="${LOCAL_DIR}/parameters.json"
SECRET="${LOCAL_DIR}/secret.json"
ALB_DIR="${LOCAL_DIR}/alb"
# The repository inside the containers (read-only).
REPO=/repo
HTTP_PORT="${LOCAL_HTTP_PORT:-8000}"
TEST_PORT="${LOCAL_TEST_PORT:-8081}"
# The Observe step: its seconds, and whether k6 makes the traffic meanwhile.
OBSERVE_SECONDS="${OBSERVE_SECONDS:-60}"
OBSERVE_LOAD="${OBSERVE_LOAD:-true}"
LOAD_RATE="${LOAD_RATE:-20}"
NAME_PATTERN='^app\.[a-z0-9.-]+$'
KEY_PATTERN='^[A-Z][A-Z0-9_]{0,63}$'

# The outputs of the Plan step, filled only by plan.
ACTIVE=""
TARGET=""
REVISION='{}'
CONFIG='{}'
SKIP=false
CONFIG_CHANGED=false
REVISION_CHANGED=false
WEIGHT=0
LOCK_OWNER=""

usage() {
  cat >&2 <<EOF_USAGE
usage: ${0##*/} up | down | status | unlock
              | instance <color> [--config <version>] | validate <color>
              | publish <zip> [--no-event] | deploy <version> [--no-promote]
              | apply [<version>]
              | rollback | switch <color> | load [<seconds>]
              | set <name> <value> | unset <name> | secret <KEY> | show
EOF_USAGE
  exit 2
}

# The argument frontier, as in bin/*.sh.
check_args() {
  case "${1:-} $#" in
    "up 1" | "down 1" | "status 1" | "unlock 1" | "rollback 1" | "apply 1" | "show 1") ;;
    "instance 2" | "validate 2" | "switch 2") require_color "$2" ;;
    "instance 4")
      require_color "$2"
      [ "$3" = --config ] && [[ "$4" =~ $VERSION_PATTERN ]] || usage ;;
    "publish 2" | "publish 3")
      [[ "${3:-}" =~ ^(--no-event)?$ ]] || usage
      [ -f "$2" ] || die "no such file: $2" ;;
    "deploy 2" | "deploy 3")
      [[ "$2" =~ $VERSION_PATTERN ]] && [[ "${3:-}" =~ ^(--no-promote)?$ ]] || usage ;;
    "apply 2") [[ "$2" =~ $VERSION_PATTERN ]] || usage ;;
    "load 1" | "load 2") [[ "${2:-60}" =~ ^[1-9][0-9]{0,3}$ ]] || usage ;;
    "set 3") [[ "$2" =~ $NAME_PATTERN && ${#3} -le 4096 && "$3" != *$'\n'* ]] || usage ;;
    "unset 2") [[ "$2" =~ $NAME_PATTERN ]] || usage ;;
    "secret 2") [[ "$2" =~ $KEY_PATTERN ]] || usage ;;
    *) usage ;;
  esac
}

# config/local.env, made from the example the first time. load_config checks it as in AWS, offline
# because there is no account; only two derived names are needed here.
load_local_config() {
  local file="${ROOT_DIR}/config/${ENV_NAME}.env"
  if [ ! -f "$file" ]; then
    sed "s/^ENV_NAME=.*/ENV_NAME=${ENV_NAME}/" "${ROOT_DIR}/config/example.env" > "$file"
    log "created config/${ENV_NAME}.env from config/example.env"
  fi
  load_config --offline
  PREFIX="wfl-${ENV_NAME}"
  CONFIG_PATH="/${PROJECT}/${ENV_NAME}/config"
  [[ "$OBSERVE_SECONDS" =~ ^[1-9][0-9]{0,3}$ ]] || die "OBSERVE_SECONDS is 1 to 9999"
  [[ "$OBSERVE_LOAD" =~ ^(true|false)$ ]] || die "OBSERVE_LOAD is true or false"
  [[ "$LOAD_RATE" =~ ^[1-9][0-9]{0,3}$ ]] || die "LOAD_RATE is 1 to 9999 requests per second"
}

compose() { docker compose --file "$COMPOSE_FILE" "$@"; }

# on COLOR COMMAND…: Run Command on an instance.
on() {
  local color="$1"
  shift
  compose exec -T "$color" "$@"
}

state_get() { cat "${STATE_DIR}/$1" 2>/dev/null || printf '%s\n' "${2:-}"; }

state_set() {
  mkdir -p "$(dirname "${STATE_DIR}/$1")"
  printf '%s\n' "$2" > "${STATE_DIR}/$1"
}

installed() { on "$1" test -f /etc/wildfly-lifecycle/instance.env 2>/dev/null; }

# The health check of a target group: HEALTH_PATH, from the load balancer to the color.
healthy() {
  compose exec -T alb curl --fail --silent --output /dev/null --max-time 5 \
    "http://$1:${APP_PORT}${HEALTH_PATH}"
}

# noclobber creates the file only if it does not exist: PutParameter without Overwrite.
lock_acquire() {
  LOCK_OWNER="local:${USER:-unknown}:$$"
  mkdir -p "$STATE_DIR"
  (set -o noclobber && printf '%s\n' "$LOCK_OWNER" > "${STATE_DIR}/lock") 2>/dev/null \
    || die "the environment is locked by $(state_get lock); if it is orphaned: ${0##*/} unlock"
  trap lock_release EXIT
}

lock_release() {
  [ -n "$LOCK_OWNER" ] && [ "$(state_get lock)" = "$LOCK_OWNER" ] || return 0
  rm -f "${STATE_DIR}/lock"
  LOCK_OWNER=""
}

# write_listeners TARGET WEIGHT ID: the listeners as nginx configuration. One upstream per target
# group, the production pool split by weight, the test pool on one color. split_clients refuses
# 0 % and 100 %: then, a map.
write_listeners() {
  local target="$1" weight="$2" id="$3" other test production
  other="$(other_color "$target")"
  test="$target"
  [ "$weight" -lt 100 ] || test="$other"
  case "$weight" in
    0) production="map \$request_id \$production_pool { default ${other}; }" ;;
    100) production="map \$request_id \$production_pool { default ${target}; }" ;;
    *)
      production="split_clients \"\${request_id}\" \$production_pool"
      production+=" { ${weight}% ${target}; * ${other}; }" ;;
  esac

  printf '%s\n' \
    "# local/run.sh: ${target} ${weight}, ${other} $((100 - weight)); test listener on ${test}" \
    "upstream blue { server blue:${APP_PORT}; }" \
    "upstream green { server green:${APP_PORT}; }" \
    "$production" \
    "map \$request_id \$test_pool { default ${test}; }" \
    "map \$request_id \$listeners_id { default ${id}; }" > "${ALB_DIR}/listeners.conf"
  state_set listeners "$(jq -cn \
    --arg target "$target" \
    --arg other "$other" \
    --arg test "$test" \
    --argjson weight "$weight" \
    '{production: {($target): $weight, ($other): (100 - $weight)}, test: $test}')"
}

# runbook.py shift_traffic: the target gets WEIGHT % and the other color the rest; the test
# listener stays on the target until it gets everything, then goes to the other color.
shift_traffic() {
  local id n
  id="$(date +%s%N)"
  write_listeners "$1" "$2" "$id"
  compose exec -T alb sh -c 'nginx -t -q && nginx -s reload' >/dev/null 2>&1 \
    || die "nginx refused build/local/alb/listeners.conf: docker compose logs alb"
  # The old workers keep answering for a moment after the reload.
  for ((n = 0; n < 50; n++)); do
    [ "$(compose exec -T alb curl --silent http://127.0.0.1:8099/)" != "$id" ] || break
    sleep 0.2
  done
  log "listeners: $(state_get listeners)"
}

wildfly_verified() {
  printf '%s  %s\n' "$WILDFLY_SHA256" "$1" | sha256sum --check --status 2>/dev/null
}

# The WildFly tarball, verified as in mirror-wildfly, and the pinned agent rpm, downloaded once.
fetch_vendor() {
  local tarball="${CACHE_DIR}/wildfly-${WILDFLY_VERSION}.tar.gz" rpm="$1"
  mkdir -p "$CACHE_DIR"
  if ! wildfly_verified "$tarball"; then
    log "downloading WildFly ${WILDFLY_VERSION}"
    curl --fail --silent --show-error --location --retry 3 --output "$tarball" \
      "https://github.com/wildfly/wildfly/releases/download/${WILDFLY_VERSION}/${tarball##*/}"
    wildfly_verified "$tarball" || die "${tarball##*/}: the SHA-256 is not WILDFLY_SHA256"
  fi

  [ ! -f "${CACHE_DIR}/${rpm}" ] || return 0
  log "downloading ${rpm}"
  curl --fail --silent --show-error --location --retry 3 --output "${CACHE_DIR}/${rpm}.part" \
    "https://aws-codedeploy-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/releases/${rpm}"
  mv "${CACHE_DIR}/${rpm}.part" "${CACHE_DIR}/${rpm}"
}

# In AWS install-wildfly.sh runs the regional installer of the agent. Here the same pinned rpm
# goes in first; install-wildfly.sh finds it with rpm -q and only enables it.
install_agent() {
  on "$1" bash -c 'rpm -q codedeploy-agent >/dev/null || dnf install -y --quiet "$1"' _ \
    "${REPO}/build/cache/$2"
}

# The InstallWildFly document: the same script, with the SSM_* variables the document sets, and
# file:// sources (its fetch accepts them) instead of S3.
install_wildfly() {
  local -a parameters=(
    "SSM_Region=${AWS_REGION}"
    "SSM_Environment=${ENV_NAME}"
    "SSM_ConfigPath=${CONFIG_PATH}"
    "SSM_SecretId=file://${REPO}/build/local/secret.json"
    "SSM_AppPort=${APP_PORT}"
    "SSM_HealthPath=${HEALTH_PATH}"
    "SSM_JavaPackage=${JAVA_PACKAGE}"
    "SSM_WildFlyVersion=${WILDFLY_VERSION}"
    "SSM_WildFlySha256=${WILDFLY_SHA256}"
    "SSM_WildFlySource=file://${REPO}/build/cache/wildfly-${WILDFLY_VERSION}.tar.gz"
    "SSM_CodeDeployAgentVersion=${CODEDEPLOY_AGENT_VERSION}"
    "SSM_PlatformSource=file://${REPO}/build/platform/platform.zip"
    "SSM_PlatformSha256=${PLATFORM_SHA256}"
  )
  local -a env=()
  local parameter
  for parameter in "${parameters[@]}"; do
    env+=(--env "$parameter")
  done
  compose exec -T "${env[@]}" "$1" bash "${REPO}/remote/install-wildfly.sh"
}

# instance.sh converge: Release on the color without promoting it.
converge() {
  local color="$1" config="$2" active
  active="$(state_get active-color blue)"
  if [ -z "$config" ] && [ "$(state_get "${active}/release" '{}')" = '{}' ] \
    && [ "$(state_get "${active}/config" '{}')" = '{}' ]; then
    warn "nothing to converge to yet: ${color} only gets WildFly (--config <version> for more)"
    return 0
  fi
  release "" "$config" "$color" false
}

# instance.sh up, without the CloudFormation stack (the container is the instance) and without
# the AMI backup.
instance() {
  local color="$1" config="$2" rpm
  rpm="codedeploy-agent-${CODEDEPLOY_AGENT_VERSION}.$(on "$color" uname -m).rpm"
  fetch_vendor "$rpm"
  build_platform
  log "InstallWildFly on ${color}"
  install_agent "$color" "$rpm"
  install_wildfly "$color"
  converge "$color" "$config"
  log "Validate on ${color}"
  on "$color" /opt/wildfly-lifecycle/bin/validate.sh >&2 || die "Validate failed on ${color}"
  log "${color} ready (shell: docker compose -f local/compose.yml exec ${color} bash)"
}

# runbook.py verified: the key is the identity; the tags (a .tags.json next to the object) are a
# mirror checked against the bytes, as the S3 checksum is in AWS.
verified() {
  local key="$1" file="${BUCKET_DIR}/$1" version sha
  version="${key%/*}"
  version="${version##*/}"
  [ -f "$file" ] || die "${key} is not published: ${0##*/} publish <zip>"
  sha="$(sha256_hex "$file")"
  jq -e --arg sha "$sha" --arg version "$version" '.Sha256 == $sha and .Version == $version' \
    "${file}.tags.json" >/dev/null || die "${key}: its tags do not match the object"
  jq -cn --arg key "$key" --arg version "$version" --arg sha "$sha" \
    '{key: $key, version: $version, sha256: $sha}'
}

# runbook.py fingerprint: the bytes of the configuration release, the sorted name=value of
# …/config and the version of the secret (here, its hash), never its values.
fingerprint() {
  local secret_version=none
  [ "$(jq -c . "$SECRET")" = '{}' ] || secret_version="$(sha256_hex "$SECRET")"
  {
    printf '%s\n' "$1"
    jq -r 'to_entries | map("\(.key)=\(.value)") | sort[]' "$PARAMETERS"
    printf '%s' "$secret_version"
  } | sha256sum | cut -d' ' -f1
}

# runbook.py plan: the target color, what to deploy (verified), what changes on the target and
# the canary weight.
plan() {
  local key="$1" version="$2" color="$3" promote="$4" live_release live_config
  ACTIVE="$(state_get active-color blue)"
  TARGET="${color:-$(other_color "$ACTIVE")}"
  if [ -z "$color" ] && ! installed "$TARGET"; then
    warn "no ${TARGET} instance: in place on ${ACTIVE}, without canary"
    TARGET="$ACTIVE"
  fi
  installed "$TARGET" || die "no WildFly on ${TARGET}: ${0##*/} instance ${TARGET}"

  live_release="$(state_get "${ACTIVE}/release" '{}')"
  live_config="$(state_get "${ACTIVE}/config" '{}')"
  [ -n "$key" ] || key="$(jq -r '.key // empty' <<<"$live_release")"
  [ -z "$key" ] || REVISION="$(verified "$key")" || exit 1
  [ -n "$version" ] || version="$(jq -r '.version // empty' <<<"$live_config")"
  if [ -n "$version" ]; then
    CONFIG="$(verified "config-releases/wildfly-config/${version}/wildfly-config-${version}.zip")" \
      || exit 1
    CONFIG="$(jq -c --arg f "$(fingerprint "$(jq -r .sha256 <<<"$CONFIG")")" \
      '{key, version, fingerprint: $f}' <<<"$CONFIG")"
  fi

  # A duplicated event after the switch: production already runs exactly this.
  SKIP="$(jq -n --arg promote "$promote" --argjson rel "$REVISION" --argjson cfg "$CONFIG" \
    --argjson live_rel "$live_release" --argjson live_cfg "$live_config" \
    '$promote == "true"
      and [$live_rel.key, $live_cfg.fingerprint] == [$rel.key, $cfg.fingerprint]')"
  CONFIG_CHANGED="$(jq -n --argjson want "$CONFIG" \
    --argjson have "$(state_get "${TARGET}/config" '{}')" \
    '$want != {} and $have.fingerprint != $want.fingerprint')"
  REVISION_CHANGED="$(jq -n --argjson want "$REVISION" \
    --argjson have "$(state_get "${TARGET}/release" '{}')" \
    '$want != {} and $have.key != $want.key')"
  WEIGHT=0
  [ "$live_release" = '{}' ] || [ "$TARGET" = "$ACTIVE" ] || WEIGHT="$CANARY_WEIGHT"
  log "Plan: target ${TARGET} (active ${ACTIVE}) · configuration changes: ${CONFIG_CHANGED}" \
    "· revision changes: ${REVISION_CHANGED} · canary: ${WEIGHT} %"
}

# ApplyConfig: what AWS-ApplyAnsiblePlaybooks does with a release from S3 (unzip it, then
# ansible-playbook -i "localhost," -c local). The values travel through the test seam of site.yml
# (config_values, and of the secret only secret_keys): the container has no Parameter Store.
apply_config() {
  local extra seam
  extra="config_path=${CONFIG_PATH} config_version=$(jq -r .version <<<"$CONFIG")"
  extra+=" fingerprint=$(jq -r .fingerprint <<<"$CONFIG")"
  seam="$(jq -cn --slurpfile values "$PARAMETERS" --slurpfile secret "$SECRET" \
    '{config_values: $values[0], secret_keys: ($secret[0] | keys)}')"
  log "ApplyConfig on ${TARGET}: configuration $(jq -r .version <<<"$CONFIG")"
  compose exec -T \
    --env "ZIP=${REPO}/build/local/bucket/$(jq -r .key <<<"$CONFIG")" \
    --env "EXTRA=${extra}" \
    --env "SEAM=${seam}" \
    "$TARGET" bash -c 'rm -rf /tmp/config-release && mkdir /tmp/config-release \
      && cd /tmp/config-release && unzip -q "$ZIP" \
      && ansible-playbook -i localhost, -c local -e "$EXTRA" -e "$SEAM" site.yml' >&2 \
    || return 1
  state_set "${TARGET}/config" "$(jq -c '{version, fingerprint}' <<<"$CONFIG")"
}

# CodeDeploy in place: the real agent runs the revision with deploy-local, with the same
# appspec.yml, hooks and platform scripts as in AWS.
codedeploy() {
  compose exec -T --workdir /tmp "$1" /opt/codedeploy-agent/bin/codedeploy-agent deploy-local \
    --bundle-location "${REPO}/build/local/bucket/$2" \
    --type zip \
    --file-exists-behavior OVERWRITE \
    --application-name "$PREFIX" \
    --deployment-group "${PREFIX}-$1" \
    --deployment-group-name "${PREFIX}-$1" >&2
}

# Deploy, WaitDeploy and RecordRelease. deploy-local has no automatic rollback, the service does:
# on DEPLOYMENT_FAILURE, a new deployment of the last good revision. So it is done here.
deploy_revision() {
  local key previous
  key="$(jq -r .key <<<"$REVISION")"
  log "Deploy on ${TARGET}: ${key}"
  if codedeploy "$TARGET" "$key"; then
    state_set "${TARGET}/release" "$REVISION"
    return 0
  fi
  previous="$(state_get "${TARGET}/release" '{}' | jq -r '.key // empty')"
  if [ -n "$previous" ]; then
    warn "the deployment failed: automatic rollback, a new deployment of ${previous}"
    codedeploy "$TARGET" "$previous" || warn "the rollback deployment failed too"
  fi
  return 1
}

# Observe: in AWS an aws:sleep of CANARY_MINUTES + 2 min, because the ALB metrics come late.
# Here the access log is immediate, and the wait is k6 traffic unless OBSERVE_LOAD=false.
observe() {
  if [ "$OBSERVE_LOAD" = true ]; then
    log "Observe: ${OBSERVE_SECONDS} s of k6 traffic"
    load "$OBSERVE_SECONDS" canary
  else
    log "Observe: ${OBSERVE_SECONDS} s; send traffic to http://localhost:${HTTP_PORT}"
    sleep "$OBSERVE_SECONDS"
  fi
}

# CheckCanary: the metrics of the target group of the new color since the weight change, from
# the access log (requests and 5XX of the target), and its health check now.
check_canary() {
  local start="$1" unhealthy=0 seen
  healthy "$TARGET" || unhealthy=1
  seen="$(jq -cn --argjson start "$start" --arg pool "$TARGET" --argjson unhealthy "$unhealthy" \
    '[inputs | select(.listener == "production" and .pool == $pool and .msec >= $start)]
      | {Errors5xx: map(select(.upstream_status | test("^5"))) | length,
         Unhealthy: $unhealthy, Requests: length}' "${ALB_DIR}/access.log")"
  log "CheckCanary on ${TARGET}: ${seen}"
  jq -e --argjson min "$CANARY_MIN_REQUESTS" \
    '.Errors5xx == 0 and .Unhealthy == 0 and .Requests >= $min' <<<"$seen" >/dev/null
}

canary() {
  local start
  shift_traffic "$TARGET" "$WEIGHT"
  start="$(date +%s.%3N)"
  observe
  check_canary "$start"
}

# Rollback: everything back to the active color, and the release fails.
rollback_traffic() {
  shift_traffic "$TARGET" 0
  die "the release failed: production is back on $(other_color "$TARGET")"
}

wait_healthy() {
  local n
  for ((n = 0; n < 30; n++)); do
    healthy "$1" && return 0
    sleep 2
  done
  warn "$1 is not healthy for the load balancer"
  return 1
}

# The Switch runbook: Validate on the color, its health check from the load balancer, 100 % to
# it with the test listener on the other color, and the active-color pointer.
switch_to() {
  local color="$1"
  log "Switch to ${color}: Validate"
  on "$color" /opt/wildfly-lifecycle/bin/validate.sh >&2 || return 1
  wait_healthy "$color" || return 1
  shift_traffic "$color" 100
  state_set active-color "$color"
  log "${color} is the active color: http://localhost:${HTTP_PORT}"
}

# The Release runbook. Before the canary a failure only unlocks; from the canary on, the traffic
# goes back first.
release() {
  local key="$1" version="$2" color="$3" promote="$4"
  lock_acquire
  plan "$key" "$version" "$color" "$promote"
  if [ "$SKIP" = true ]; then
    log "Skip: ${ACTIVE} already runs this revision and this configuration"
    return 0
  fi
  if [ "$CONFIG_CHANGED" = true ]; then
    apply_config || die "ApplyConfig failed on ${TARGET}: standalone.xml was restored"
  fi
  if [ "$REVISION_CHANGED" = true ]; then
    deploy_revision || die "Deploy failed on ${TARGET}; production did not change"
  fi
  if [ "$promote" = false ]; then
    log "Promote=false: ${TARGET} converged; the traffic does not move"
    return 0
  fi
  # onCancel of Canary, Observe, CheckCanary and Switch: Rollback (Ctrl+C here).
  trap rollback_traffic INT TERM
  if [ "$WEIGHT" -gt 0 ]; then
    canary || rollback_traffic
  fi
  switch_to "$TARGET" || rollback_traffic
}

# PutObject with --if-none-match '*' (a version is written once: 412 otherwise) and the tags.
# A revision is an Object Created event for EventBridge, which starts Release, unless --no-event
# (as with the rule disabled); a configuration release starts nothing.
publish() {
  local zip="$1" event="$2" name="${1##*/}" version key
  case "$name" in
    "${APP_NAME}"-*.zip)
      version="${name#"${APP_NAME}-"}"
      key="releases/${APP_NAME}/${version%.zip}/${name}" ;;
    wildfly-config-*.zip)
      version="${name#wildfly-config-}"
      key="config-releases/wildfly-config/${version%.zip}/${name}" ;;
    *) die "${name} is neither ${APP_NAME}-<version>.zip nor wildfly-config-<version>.zip" ;;
  esac
  [[ "${version%.zip}" =~ $VERSION_PATTERN ]] || die "${name}: not a version of the contract"
  [ ! -e "${BUCKET_DIR}/${key}" ] \
    || die "412 Precondition Failed: ${key} is already published; publish a new version"

  mkdir -p "$(dirname "${BUCKET_DIR}/${key}")"
  cp "$zip" "${BUCKET_DIR}/${key}"
  jq -n --arg version "${version%.zip}" --arg sha "$(sha256_hex "$zip")" --arg git "$(git_sha)" \
    '{Version: $version, Sha256: $sha, GitSha: $git}' > "${BUCKET_DIR}/${key}.tags.json"
  log "published ${key} (sha256 $(sha256_hex "$zip"))"

  case "${key}${event}" in
    releases/*--no-event) log "no event: ${0##*/} deploy ${version%.zip} [--no-promote]" ;;
    releases/*)
      log "Object Created → EventBridge → Release"
      release "$key" "" "" true ;;
    *) log "nothing is applied yet: ${0##*/} apply ${version%.zip}" ;;
  esac
}

rollback() {
  local target
  target="$(other_color "$(state_get active-color blue)")"
  show_colors
  [ "$(state_get "${target}/release" '{}')" != '{}' ] || die "${target} has no release to go back"
  lock_acquire
  log "production goes back to ${target}"
  switch_to "$target" || die "Switch to ${target} failed"
}

switch() {
  lock_acquire
  switch_to "$1" || die "Switch to $1 failed"
}

show_colors() {
  local color answer
  for color in blue green; do
    answer="$(compose exec -T alb curl --fail --silent --max-time 3 \
      "http://${color}:${APP_PORT}/version" 2>/dev/null)" || answer="no answer"
    log "${color}: release $(state_get "${color}/release" '{}' | jq -r '.version // "none"')," \
      "config $(state_get "${color}/config" '{}' | jq -r '.version // "none"')," \
      "/version: ${answer}"
  done
}

status() {
  log "active color: $(state_get active-color none) · lock: $(state_get lock free)"
  log "listeners: $(state_get listeners '{}')"
  show_colors
  log "production http://localhost:${HTTP_PORT} · test listener http://localhost:${TEST_PORT}"
}

unlock() {
  local owner
  owner="$(state_get lock)"
  [ -n "$owner" ] || { log "no lock"; return 0; }
  log "lock held by ${owner}"
  confirm "Delete the lock?"
  rm -f "${STATE_DIR}/lock"
}

# k6 against the production listener; the summary goes to build/local/results/.
load() {
  local seconds="$1" name
  name="${2:-load}-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${LOCAL_DIR}/results"
  compose run --rm --user "$(id -u):$(id -g)" \
    --env "DURATION=${seconds}s" \
    --env "RATE=${LOAD_RATE}" \
    --env "APP_PORT=${APP_PORT}" \
    --env "RESULT=/results/${name}" \
    load >&2 || warn "k6 ended with an error"
  log "results: build/local/results/${name}.txt and ${name}.json"
}

# Parameter Store …/config, as a JSON object.
set_parameter() {
  jq --arg name "$1" --arg value "$2" '.[$name] = $value' "$PARAMETERS" > "${PARAMETERS}.new"
  mv "${PARAMETERS}.new" "$PARAMETERS"
  log "$1 set; it reaches the instances with: ${0##*/} apply"
}

unset_parameter() {
  jq --arg name "$1" 'del(.[$name])' "$PARAMETERS" > "${PARAMETERS}.new"
  mv "${PARAMETERS}.new" "$PARAMETERS"
  log "$1 deleted; it leaves the instances with: ${0##*/} apply"
}

# The secret, as a JSON object: the value comes from stdin, never as an argument.
set_secret() {
  local value
  if [ -t 0 ]; then
    read -rs -p "$1: " value
    echo >&2
  else
    IFS= read -r value
  fi
  [ -n "$value" ] || die "empty value"
  (umask 0077 && jq --arg key "$1" --rawfile value /dev/fd/3 '.[$key] = ($value | rtrimstr("\n"))' \
    "$SECRET" 3<<<"$value" > "${SECRET}.new")
  mv "${SECRET}.new" "$SECRET"
  log "$1 stored; WildFly reads it after: ${0##*/} apply"
}

show() {
  log "parameters (…/config): $(jq -c . "$PARAMETERS")"
  log "keys of the secret: $(jq -c keys "$SECRET")"
}

wait_systemd() {
  local n state
  for ((n = 0; n < 60; n++)); do
    state="$(on "$1" systemctl is-system-running 2>/dev/null)" || true
    [[ "$state" =~ ^(running|degraded)$ ]] && return 0
    sleep 1
  done
  die "systemd did not start in $1: docker compose -f local/compose.yml logs $1"
}

# A container that Compose created again is a new instance: what the state says it has is gone,
# as instance.sh down deletes it in AWS.
forget_new_instances() {
  local color
  for color in blue green; do
    ! installed "$color" || continue
    [ -d "${STATE_DIR}/${color}" ] || continue
    rm -rf "${STATE_DIR:?}/${color}"
    warn "${color} is a new container: its state is reset; ${0##*/} instance ${color}"
  done
}

# The empty state that setup.sh up leaves in AWS. The directories are created here, not by Docker,
# which would create them as root.
init_state() {
  mkdir -p "$ALB_DIR" "$STATE_DIR" "$BUCKET_DIR" "${LOCAL_DIR}/results"
  [ -f "$PARAMETERS" ] || printf '{}\n' > "$PARAMETERS"
  [ -f "$SECRET" ] || (umask 0077 && printf '{}\n' > "$SECRET")
  touch "${ALB_DIR}/access.log"
  [ -f "${STATE_DIR}/active-color" ] || state_set active-color blue
}

# setup.sh up and alb.sh up of the local environment: the containers, and the listeners on the
# active color.
up() {
  write_listeners "$(state_get active-color)" 100 "$(date +%s%N)"

  # Built only once: a rebuilt image makes Compose recreate blue and green, which are then new
  # instances without WildFly.
  docker image inspect wfl-local-instance >/dev/null 2>&1 || compose build
  compose up --detach
  compose --profile load pull --quiet load
  wait_systemd blue
  wait_systemd green
  forget_new_instances
  # An nginx that was already running reloads the file written above.
  shift_traffic "$(state_get active-color)" 100
  log "blue, green and the ALB are up: production on :${HTTP_PORT}, test listener on :${TEST_PORT}"
}

down() {
  compose --profile load down --volumes --remove-orphans
  rm -rf "$LOCAL_DIR"
  log "containers and build/local/ removed (build/cache/ and the zips of build/ stay)"
}

main() {
  check_args "$@"
  require_cmd docker jq curl sha256sum
  load_local_config
  [ "$1" = down ] || init_state

  case "$1" in
    up) up ;;
    down) down ;;
    status) status ;;
    unlock) unlock ;;
    instance) instance "$2" "${4:-}" ;;
    validate) on "$2" /opt/wildfly-lifecycle/bin/validate.sh ;;
    publish) publish "$2" "${3:-}" ;;
    deploy)
      release "releases/${APP_NAME}/$2/${APP_NAME}-$2.zip" "" "" \
        "$([ "${3:-}" = --no-promote ] && echo false || echo true)" ;;
    apply) release "" "${2:-}" "" true ;;
    rollback) rollback ;;
    switch) switch "$2" ;;
    load) load "${2:-60}" ;;
    set) set_parameter "$2" "$3" ;;
    unset) unset_parameter "$2" ;;
    secret) set_secret "$2" ;;
    show) show ;;
  esac
}

main "$@"
