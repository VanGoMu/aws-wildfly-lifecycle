#!/usr/bin/env bash
# Logging, the configuration (its only validation), derived names and tags. Every bin/*.sh
# sources this file first; functions downstream trust what load_config exported.

PROJECT=aws-wildfly-lifecycle
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT ROOT_DIR AWS_PAGER=""

# A release version: semver without build metadata, so the S3 key never needs URL encoding in
# the event. The git tag v1.2.0 (or config-v1.2.0) gives 1.2.0. Both patterns are for bin/*.sh.
# shellcheck disable=SC2034
VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
# shellcheck disable=SC2034
WAR_PATTERN='^[A-Za-z0-9._-]+\.war$'
CIDR='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'

# Every configuration key and the format it must have.
declare -rA CONFIG_PATTERNS=(
  [ENV_NAME]='^[a-z][a-z0-9]{0,9}$'
  [AWS_REGION]='^[a-z]{2}(-[a-z]+)+-[0-9]$'
  [VPC_ID]='^(vpc-[0-9a-f]{8,17})?$'
  [SUBNET_IDS]='^(subnet-[0-9a-f]{8,17}(,subnet-[0-9a-f]{8,17})+)?$'
  [ASSIGN_PUBLIC_IP]='^(true|false)$'
  [INSTANCE_TYPE]='^[a-z][a-z0-9-]*\.[a-z0-9]+$'
  [USE_ALB]='^(true|false)$'
  [ALLOWED_CIDR]="$CIDR"
  [ALB_INGRESS_CIDR]="$CIDR"
  [CERTIFICATE_ARN]='^(arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]+)?$'
  [CANARY_WEIGHT]='^([0-9]|[1-4][0-9]|50)$'
  [CANARY_MINUTES]='^([1-9]|[1-5][0-9]|60)$'
  [CANARY_MIN_REQUESTS]='^[0-9]{1,6}$'
  [APP_NAME]='^[a-z][a-z0-9-]{1,30}$'
  [APP_PORT]='^[1-9][0-9]{3,4}$'
  [HEALTH_PATH]='^/[A-Za-z0-9/_.-]*$'
  [WILDFLY_VERSION]='^[0-9]+\.[0-9]+\.[0-9]+\.Final$'
  [WILDFLY_SHA256]='^[0-9a-f]{64}$'
  [JAVA_PACKAGE]='^[a-z0-9][a-z0-9.+-]*$'
  [CODEDEPLOY_AGENT_VERSION]='^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$'
  [COMMUNITY_GENERAL_VERSION]='^[0-9]+\.[0-9]+\.[0-9]+$'
  [COMMUNITY_GENERAL_SHA256]='^[0-9a-f]{64}$'
  [AMI_BACKUPS_KEEP]='^[1-9]$'
  [GITHUB_REPOSITORY]='^([A-Za-z0-9-]+/[A-Za-z0-9._-]+)?$'
  [CREATE_OIDC_PROVIDER]='^(true|false)$'
)

log() { printf '%s · %s\n' "${0##*/}" "$*" >&2; }
warn() { printf '%s · WARNING: %s\n' "${0##*/}" "$*" >&2; }
die() { printf '%s · ERROR: %s\n' "${0##*/}" "$*" >&2; exit 1; }

require_cmd() {
  local name
  for name in "$@"; do
    command -v "$name" >/dev/null 2>&1 || die "missing command: ${name}"
  done
}

# retry ATTEMPTS DELAY COMMAND…: for what AWS makes eventually consistent (a new IAM role).
retry() {
  local attempts="$1" delay="$2" n
  shift 2
  for ((n = 1; ; n++)); do
    "$@" && return 0
    ((n < attempts)) || return 1
    warn "attempt ${n}/${attempts} failed; retrying in ${delay} s"
    sleep "$delay"
  done
}

confirm() {
  local answer
  [ "${FORCE:-0}" = 1 ] && return 0
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]] || die "cancelled"
}

# read_env_file FILE: KEY=value lines into CONFIG_VALUES. Parsed, never sourced: a configuration
# file runs no code.
read_env_file() {
  local file="$1" line key
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || die "${file}: not a KEY=value line: ${line}"
    key="${BASH_REMATCH[1]}"
    [ -n "${CONFIG_PATTERNS[$key]+set}" ] || die "${file}: unknown key ${key}"
    CONFIG_VALUES[$key]="${BASH_REMATCH[2]}"
  done < "$file"
}

# load_config [--offline]: config/<env>.env, then the environment, which wins. --offline
# validates without asking AWS who we are (a local build).
load_config() {
  local key identity file
  local -a invalid=()
  declare -gA CONFIG_VALUES=()
  ENV_NAME="${ENV_NAME:-dev}"
  [[ "$ENV_NAME" =~ ${CONFIG_PATTERNS[ENV_NAME]} ]] || die "invalid ENV_NAME: ${ENV_NAME}"
  file="${ROOT_DIR}/config/${ENV_NAME}.env"
  [ -f "$file" ] || warn "no config/${ENV_NAME}.env: cp config/example.env config/${ENV_NAME}.env"
  read_env_file "$file"
  CONFIG_VALUES[ENV_NAME]="$ENV_NAME"

  for key in "${!CONFIG_PATTERNS[@]}"; do
    [ -n "${!key+set}" ] && CONFIG_VALUES[$key]="${!key}"
    [[ "${CONFIG_VALUES[$key]-}" =~ ${CONFIG_PATTERNS[$key]} ]] \
      || invalid+=("${key}='${CONFIG_VALUES[$key]-}'")
    export "${key}=${CONFIG_VALUES[$key]-}"
  done
  ((${#invalid[@]} == 0)) || die "invalid configuration: ${invalid[*]}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  [ "${1:-}" != --offline ] || return 0

  identity=$(aws sts get-caller-identity --query '[Account, Arn]' --output text) \
    || die "no valid AWS credentials"
  read -r ACCOUNT_ID CALLER_ARN <<<"$identity"
  AWS_PARTITION="${CALLER_ARN#arn:}"
  AWS_PARTITION="${AWS_PARTITION%%:*}"
  export ACCOUNT_ID CALLER_ARN AWS_PARTITION
  derive_names
}

# require_config KEY…: what this script needs, in one line, after load_config.
require_config() {
  local key
  local -a missing=()
  for key in "$@"; do
    [ -n "${!key:-}" ] || missing+=("$key")
  done
  ((${#missing[@]} == 0)) || die "missing in config/${ENV_NAME}.env: ${missing[*]}"
}

derive_names() {
  PREFIX="wfl-${ENV_NAME}"
  STACK_FOUNDATION="${PREFIX}-foundation"
  STACK_ALB="${PREFIX}-alb"
  BUCKET="${PREFIX}-${ACCOUNT_ID}-${AWS_REGION}"
  DOC_INSTALL="${PREFIX}-InstallWildFly"
  DOC_VALIDATE="${PREFIX}-Validate"
  DOC_RELEASE="${PREFIX}-Release"
  DOC_SWITCH="${PREFIX}-Switch"
  PARAM_ROOT="/${PROJECT}/${ENV_NAME}"
  CONFIG_PATH="${PARAM_ROOT}/config"
  STATE_PATH="${PARAM_ROOT}/state"
  INFRA_ALB="${PARAM_ROOT}/infra/alb"
  SECRET_ID="${PROJECT}/${ENV_NAME}/app"
  AUTOMATION_ROLE_ARN="arn:${AWS_PARTITION}:iam::${ACCOUNT_ID}:role/${PREFIX}-automation"
  export PREFIX STACK_FOUNDATION STACK_ALB BUCKET DOC_INSTALL DOC_VALIDATE DOC_RELEASE DOC_SWITCH
  export PARAM_ROOT CONFIG_PATH STATE_PATH INFRA_ALB SECRET_ID AUTOMATION_ROLE_ARN
}

color_stack() { printf '%s-%s' "$PREFIX" "$1"; }
other_color() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }
require_color() { [[ "${1:-}" =~ ^(blue|green)$ ]] || die "the color is blue or green"; }

# tags COMPONENT [KEY=VALUE…]: the tags of everything this repository creates, one per line.
tags() {
  printf '%s\n' "Project=${PROJECT}" "Environment=${ENV_NAME}" "Component=$1"
  shift
  [ "$#" -eq 0 ] || printf '%s\n' "$@"
}

# parameters_json NAME=VALUE…: the {"Name": ["value"]} map that SSM documents take.
parameters_json() {
  jq -cn '$ARGS.positional | map(capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): [.v]}) | add // {}' \
    --args "$@"
}
