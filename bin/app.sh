#!/usr/bin/env bash
# Automation 5 · the application lifecycle. Publishing a revision already deploys it (EventBridge
# → Release); deploy starts the same runbook from here for a version already published. rollback
# switches to the idle color, which keeps the previous release. Also status, unlock and load.
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
  echo "usage: ${0##*/} deploy <version> | rollback | status | unlock | load <minutes>" >&2
  exit 2
}

show_colors() {
  local color
  for color in blue green; do
    log "${color}: release $(state_get "${color}/release" '{}' | jq -r '.version // "none"'), \
config $(state_get "${color}/config" '{}' | jq -r '.version // "none"')"
  done
}

deploy() {
  local key="releases/${APP_NAME}/$1/${APP_NAME}-$1.zip"
  start_runbook "$DOC_RELEASE" "RevisionKey=${key}" Promote=true || die "Release $1 failed"
}

# The idle color keeps the previous release: going back is only the Switch runbook.
rollback() {
  local target
  target=$(other_color "$(state_get active-color blue)")
  show_colors
  [ "$(state_get "${target}/release" '{}')" != '{}' ] || die "${target} has no release to go back"
  lock_acquire
  log "production goes back to ${target}"
  start_runbook "$DOC_SWITCH" "TargetColor=${target}" || die "Switch to ${target} failed"
}

status() {
  log "active color: $(state_get active-color none) · lock: $(state_get lock free)"
  show_colors
  [ "$USE_ALB" = false ] || "${ROOT_DIR}/bin/alb.sh" status
  log "latest ${DOC_RELEASE} executions:"
  aws ssm describe-automation-executions \
    --filters "Key=DocumentNamePrefix,Values=${DOC_RELEASE}" \
    --max-results 5 \
    --query 'AutomationExecutionMetadataList[].[ExecutionStartTime, AutomationExecutionStatus,
      AutomationExecutionId]' \
    --output text | sed 's/^/  /' >&2
}

# An orphaned lock: an execution that died without its Unlock step, or a killed bin/*.sh.
unlock() {
  local owner status
  owner=$(state_get lock)
  [ -n "$owner" ] || { log "no lock"; return 0; }
  status=$(aws ssm get-automation-execution \
    --automation-execution-id "$owner" \
    --query AutomationExecution.AutomationExecutionStatus \
    --output text 2>/dev/null) || status="not an Automation execution"
  log "lock held by ${owner} (${status})"
  confirm "Delete the lock?"
  aws ssm delete-parameter --name "${STATE_PATH}/lock"
}

# With little traffic the 10 % of almost nothing gives the canary no signal: this makes some.
load() {
  local minutes="$1" url end answer
  local -A seen=()
  url="http://$(stack_output "$STACK_ALB" LoadBalancerDnsName)"
  [ "$url" != http:// ] || die "no load balancer (${STACK_ALB})"
  [ -z "$CERTIFICATE_ARN" ] || url="${url/http:/https:}"
  end=$(($(date +%s) + minutes * 60))
  log "requests to ${url}/version for ${minutes} min"
  while [ "$(date +%s)" -lt "$end" ]; do
    answer=$(curl --silent --max-time 5 --write-out ' (%{http_code})' "${url}/version" \
      | tr -d '\r\n') || true
    seen[$answer]=$((${seen[$answer]:-0} + 1))
  done
  for answer in "${!seen[@]}"; do
    log "  ${seen[$answer]} × ${answer}"
  done
}

main() {
  case "${1:-} $#" in
    "deploy 2") [[ "$2" =~ $VERSION_PATTERN ]] || usage ;;
    "rollback 1" | "status 1" | "unlock 1") ;;
    "load 2") [[ "$2" =~ ^[1-9][0-9]?$ ]] || usage ;;
    *) usage ;;
  esac
  load_config
  require_config APP_NAME

  case "$1" in
    deploy) deploy "$2" ;;
    rollback) rollback ;;
    status) status ;;
    unlock) unlock ;;
    load) load "$2" ;;
  esac
}

main "$@"
