#!/usr/bin/env bash
# 3 · Instantiation of a color. up: its stack, Systems Manager Online, InstallWildFly, converge it
# with Release (Promote=false: what the active color has, or --config), Validate, and an AMI
# backup that proves the service survives a boot. Also validate, backup, down and status.
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${LIB}/common.sh"
# shellcheck source=lib/cfn.sh
source "${LIB}/cfn.sh"
# shellcheck source=lib/ssm.sh
source "${LIB}/ssm.sh"
# shellcheck source=lib/automation.sh
source "${LIB}/automation.sh"
# shellcheck source=lib/ami.sh
source "${LIB}/ami.sh"

BASE_AMI_PARAMETER=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64

usage() {
  cat >&2 <<EOF_USAGE
usage: ${0##*/} up <color> [--from-ami <ami-id|latest>] [--config <version>] [--force]
                   | validate <color> | backup <color> | down <color> [--force] | status
EOF_USAGE
  exit 2
}

instance_id() { stack_output "$(color_stack "$1")" InstanceId; }
target_group() { infra_alb ".targetGroups.$1.arn // empty"; }
has_release() { [ "$(state_get "$1/release" '{}')" != '{}' ]; }
has_config() { [ "$(state_get "$1/config" '{}')" != '{}' ]; }

# Touching the active color behind an ALB is touching production: only with --force.
refuse_active() {
  [ "$2" = 0 ] && [ "$1" = "$(state_get active-color blue)" ] && [ -n "$(target_group "$1")" ] \
    && [ -n "$(instance_id "$1")" ] && die "$1 is the active color behind the ALB: --force"
  return 0
}

# The AMI is chosen when the stack is created or when asked for: otherwise a new Amazon Linux
# release would replace the instance on the next up.
ensure_stack() {
  local color="$1" ami="$2" stack subnet
  local -a subnets overrides=()
  stack="$(color_stack "$color")"
  IFS=, read -ra subnets <<<"$SUBNET_IDS"
  subnet="${subnets[0]}"
  [ "$color" = blue ] || subnet="${subnets[1]}"
  case "$ami:$(stack_status "$stack")" in
    latest:*) overrides=("AmiId=$(latest_backup)") ;;
    ami-*) overrides=("AmiId=${ami%%:*}") ;;
    :NONE | :ROLLBACK_COMPLETE)
      overrides=("AmiId=$(aws ssm get-parameter --name "$BASE_AMI_PARAMETER" \
        --query Parameter.Value --output text)") ;;
  esac
  [ "${overrides[0]:-}" != AmiId=None ] || die "no backup AMI in ${ENV_NAME}"
  # A brand-new instance profile can be refused for a few seconds (IAM eventual consistency).
  retry 3 30 deploy_stack "$stack" instance.yml compute \
    "${overrides[@]}" \
    "Prefix=${PREFIX}" \
    "Color=${color}" \
    "InstanceType=${INSTANCE_TYPE}" \
    "VpcId=${VPC_ID}" \
    "SubnetId=${subnet}" \
    "AssignPublicIp=${ASSIGN_PUBLIC_IP}" \
    "InstanceProfileName=$(stack_output "$STACK_FOUNDATION" InstanceProfileName)" \
    "AppPort=${APP_PORT}" \
    "AllowedCidr=${ALLOWED_CIDR}" \
    "AlbSecurityGroupId=$(infra_alb '.albSecurityGroupId // empty')" || die "$stack failed"
}

# CloudFormation cannot add targets to a target group of another stack.
register_target() {
  local tg
  tg="$(target_group "$1")"
  [ -z "$tg" ] || aws elbv2 register-targets --target-group-arn "$tg" --targets "Id=$2"
}

# Without any WAR, HEALTH_PATH does not answer: the target is only waited for with a release.
validate() {
  local color="$1" instance="$2" tg
  [ -n "$instance" ] || die "there is no ${color} instance"
  run_document "$DOC_VALIDATE" "$instance" || die "Validate failed on ${instance}"
  tg="$(target_group "$color")"
  if [ -n "$tg" ] && has_release "$color"; then
    aws elbv2 wait target-in-service \
      --target-group-arn "$tg" \
      --targets "Id=${instance}" || die "${instance} is not healthy in its target group"
  fi
}

converge() {
  local color="$1" config="$2" active
  active="$(state_get active-color blue)"
  if [ -z "$config" ] && ! has_release "$active" && ! has_config "$active"; then
    warn "nothing to converge to yet: ${color} only gets WildFly (--config <version> for more)"
    return 0
  fi
  start_runbook "$DOC_RELEASE" "TargetColor=${color}" Promote=false "ConfigVersion=${config}" \
    || die "Release failed on ${color}"
}

# create-image reboots the instance: on the active color that is an outage.
backup() {
  local color="$1" instance="$2"
  [ -n "$instance" ] || die "there is no ${color} instance"
  [ "$color" != "$(state_get active-color blue)" ] || warn "${color} is active: the reboot cuts it"
  create_backup "$instance" "$color" >/dev/null || die "the AMI of ${instance} failed"
  rotate_backups "$AMI_BACKUPS_KEEP"
}

up() {
  local color="$1" ami="$2" config="$3" force="$4" instance
  refuse_active "$color" "$force"
  ensure_stack "$color" "$ami"
  instance="$(instance_id "$color")"
  register_target "$color" "$instance"
  wait_online "$instance"
  run_document "$DOC_INSTALL" "$instance" || die "InstallWildFly failed on ${instance}"
  converge "$color" "$config"
  validate "$color" "$instance"
  backup "$color" "$instance"
  validate "$color" "$instance"
  log "${color} ready: ${instance} (shell: aws ssm start-session --target ${instance})"
}

down() {
  local color="$1" force="$2" instance tg
  refuse_active "$color" "$force"
  instance="$(instance_id "$color")"
  tg="$(target_group "$color")"
  if [ -n "$instance" ] && [ -n "$tg" ]; then
    aws elbv2 deregister-targets --target-group-arn "$tg" --targets "Id=${instance}"
  fi
  delete_stack "$(color_stack "$color")"
  aws ssm delete-parameters \
    --names "${STATE_PATH}/${color}/release" "${STATE_PATH}/${color}/config" >/dev/null
}

status() {
  local color instance tg
  log "active color: $(state_get active-color none)"
  for color in blue green; do
    instance="$(instance_id "$color")"
    log "${color}: stack $(stack_status "$(color_stack "$color")"), instance ${instance:-none}"
    [ -n "$instance" ] || continue
    log "  SSM $(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance}" \
      --query 'InstanceInformationList[0].PingStatus' --output text)"
    tg="$(target_group "$color")"
    [ -z "$tg" ] || log "  target $(aws elbv2 describe-target-health --target-group-arn "$tg" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
    log "  release $(state_get "${color}/release" '{}' | jq -c '{version, versionId}')"
    log "  config $(state_get "${color}/config" '{}' | jq -c '{version, fingerprint}')"
    log "  validate $(run_document "$DOC_VALIDATE" "$instance" 2>/dev/null | tail -n 1)"
  done
}

main() {
  local force=0 ami="" config=""
  local -a options=("${@:3}")
  case "${1:-}" in
    up | down) require_color "${2:-}" ;;
    validate | backup) [ "$#" = 2 ] || usage; require_color "$2" ;;
    status) [ "$#" = 1 ] || usage ;;
    *) usage ;;
  esac
  while [ "${#options[@]}" -gt 0 ]; do
    case "$1 ${options[0]} ${options[1]:-}" in
      "up --force "* | "down --force "*) force=1; options=("${options[@]:1}"); continue ;;
      "up --from-ami "*)
        [[ "${options[1]:-}" =~ ^(ami-[0-9a-f]{8,17}|latest)$ ]] || usage
        ami="${options[1]}" ;;
      "up --config "*)
        [[ "${options[1]:-}" =~ $VERSION_PATTERN ]] || usage
        config="${options[1]}" ;;
      *) usage ;;
    esac
    options=("${options[@]:2}")
  done
  load_config
  require_config VPC_ID SUBNET_IDS INSTANCE_TYPE ALLOWED_CIDR APP_PORT AMI_BACKUPS_KEEP

  case "$1" in
    up) up "$2" "$ami" "$config" "$force" ;;
    down) down "$2" "$force" ;;
    validate) validate "$2" "$(instance_id "$2")" ;;
    backup) backup "$2" "$(instance_id "$2")" ;;
    status) status ;;
  esac
}

main "$@"
