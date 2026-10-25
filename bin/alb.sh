#!/usr/bin/env bash
# 1 · The load balancer, optional: with USE_ALB=false everything works without it. up and down
# deploy and delete templates/alb.yml (and with it …/infra/alb); switch starts the Switch runbook;
# status shows the weights and the health of each target group. No bin/*.sh moves the traffic.
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
# shellcheck source=lib/lock.sh
source "${LIB}/lock.sh"

usage() {
  echo "usage: ${0##*/} up | down | status | switch <blue|green>" >&2
  exit 2
}

# The weights and the test color of the live listeners, as parameters of alb.yml: the runbooks
# move them outside CloudFormation, and an update must write the values already in place.
live_parameters() {
  local infra blue green test
  infra=$(infra_alb)
  [ -n "$infra" ] || return 0
  read -r blue green < <(aws elbv2 describe-listeners \
    --listener-arns "$(jq -r .productionListenerArn <<<"$infra")" \
    --output json | jq -r --argjson infra "$infra" '
      .Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups as $groups
      | [$infra.targetGroups.blue.arn, $infra.targetGroups.green.arn]
      | map(. as $arn | $groups[] | select(.TargetGroupArn == $arn) | .Weight) | @tsv')
  test=$(aws elbv2 describe-listeners \
    --listener-arns "$(jq -r .testListenerArn <<<"$infra")" \
    --output json | jq -r '.Listeners[0].DefaultActions[0]
      | .TargetGroupArn // .ForwardConfig.TargetGroups[0].TargetGroupArn')
  [ "$test" = "$(jq -r .targetGroups.blue.arn <<<"$infra")" ] && test=blue || test=green
  printf '%s\n' "BlueWeight=${blue}" "GreenWeight=${green}" "TestColor=${test}"
}

up() {
  local color
  local -a live=()
  [ "$USE_ALB" = true ] || { log "USE_ALB=false: no load balancer"; return 0; }
  if [ "$(stack_status "$STACK_ALB")" != NONE ]; then
    lock_acquire
    mapfile -t live < <(live_parameters)
  fi
  deploy_stack "$STACK_ALB" alb.yml alb \
    "${live[@]}" \
    "Prefix=${PREFIX}" \
    "ParameterRoot=${PARAM_ROOT}" \
    "VpcId=${VPC_ID}" \
    "SubnetIds=${SUBNET_IDS}" \
    "AppPort=${APP_PORT}" \
    "HealthPath=${HEALTH_PATH}" \
    "AlbIngressCidr=${ALB_INGRESS_CIDR}" \
    "AllowedCidr=${ALLOWED_CIDR}" \
    "CertificateArn=${CERTIFICATE_ARN}" || die "${STACK_ALB} failed"
  lock_release
  log "http://$(stack_output "$STACK_ALB" LoadBalancerDnsName)"
  for color in blue green; do
    [ "$(stack_status "$(color_stack "$color")")" = NONE ] \
      || warn "${color} existed before the ALB: bin/instance.sh up ${color} (--force if active)"
  done
}

# The instance security groups reference the ALB's: they go back to ALLOWED_CIDR first, or the
# ALB security group cannot be deleted.
down() {
  local color
  lock_acquire
  for color in blue green; do
    [ "$(stack_status "$(color_stack "$color")")" = NONE ] && continue
    deploy_stack "$(color_stack "$color")" instance.yml compute "AlbSecurityGroupId=" \
      || die "could not detach ${color} from the ALB"
  done
  delete_stack "$STACK_ALB"
}

status() {
  local infra color
  infra=$(infra_alb)
  [ -n "$infra" ] || { log "no load balancer (${INFRA_ALB} does not exist)"; return 0; }
  log "production listener: weight · target group"
  aws elbv2 describe-listeners \
    --listener-arns "$(jq -r .productionListenerArn <<<"$infra")" \
    --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[].[Weight, TargetGroupArn]' \
    --output text | sed -E 's|arn:.*:targetgroup/([^/]+)/.*|\1|; s/^/  /' >&2
  for color in blue green; do
    log "${color}: $(aws elbv2 describe-target-health \
      --target-group-arn "$(jq -r ".targetGroups.${color}.arn" <<<"$infra")" \
      --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State]' \
      --output text | tr '\t\n' ': ')"
  done
}

switch() {
  lock_acquire
  start_runbook "$DOC_SWITCH" "TargetColor=$1" || die "Switch to $1 failed"
}

main() {
  case "${1:-} $#" in
    "up 1" | "down 1" | "status 1") ;;
    "switch 2") require_color "$2" ;;
    *) usage ;;
  esac
  load_config
  require_config VPC_ID SUBNET_IDS APP_PORT HEALTH_PATH ALB_INGRESS_CIDR ALLOWED_CIDR

  case "$1" in
    up) up ;;
    down) down ;;
    status) status ;;
    switch) switch "$2" ;;
  esac
}

main "$@"
